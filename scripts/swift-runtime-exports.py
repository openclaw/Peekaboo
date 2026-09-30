#!/usr/bin/env python3
"""Generate, check, and audit versioned macOS Swift runtime exports (tbd v4 only).

Baseline format (UTF-8, LF; sections and symbols sorted; reexports first):
    # Peekaboo Swift runtime export baseline. Generated; do not edit.
    # Regenerate: python3 scripts/swift-runtime-exports.py generate --oldest-installed --output <this file>
    format: 1
    sdk: MacOSX26.5.sdk
    sdk-version: 26.5
    sdk-build: 25F70
    architectures: arm64 x86_64
    source-sha256: <hex>
    libraries: <count>
    symbols: <count>

    [libswiftCore]
    reexport * libswift_DarwinFoundation1
    * _swift_retain
    x86_64 _$sSByxs7Float80VcfCTj

The arch token is * for both architectures, otherwise arm64 or x86_64. Counts
refer to library sections and symbol lines, not duplicated per-arch entries.
"""

import argparse
from collections import Counter
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


ARCHES = ("arm64", "x86_64")
TARGETS = {"arm64-macos": "arm64", "arm64e-macos": "arm64", "x86_64-macos": "x86_64"}
TOP_KEYS = set("""tbd-version targets uuids flags install-name current-version compatibility-version
    swift-abi-version parent-umbrella allowable-clients reexported-libraries exports reexports
    undefineds rpaths""".split())
EXPORT_KEYS = set("""targets symbols weak-symbols thread-local-symbols objc-classes objc-eh-types
    objc-ivars""".split())
HEADER_KEYS = ("format", "sdk", "sdk-version", "sdk-build", "architectures", "source-sha256",
               "libraries", "symbols")
NM_IMPORT = re.compile(
    r"^\s*\(undefined[^)]*\)\s+(?P<weak>weak\s+)?(?:\[[^\]]*\]\s+)*external\s+"
    r"(?P<symbol>\S+)\s+\(from\s+(?P<library>[^)]+)\)\s*$"
)


class AuditError(Exception):
    pass


def fail(message):
    raise AuditError(message)


def version(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        fail("invalid macOS version: " + value)
    parts = tuple(int(part) for part in value.split("."))
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def name(value):
    if not value or any(char.isspace() for char in value):
        fail("empty name or whitespace in symbol/library name: " + repr(value))
    return value


def library_name(value):
    name(value)
    return name(Path(value).name.removesuffix(".dylib"))


def run(arguments):
    result = subprocess.run([str(arg) for arg in arguments], capture_output=True, text=True)
    if result.returncode:
        fail("command failed: " + " ".join(str(arg) for arg in arguments) + "\n" + result.stderr.strip())
    return result.stdout


@dataclass
class SDK:
    path: Path
    version: str
    canonical_name: str
    build: str

    def key(self):
        return version(self.version), self.build, str(self.path)


def read_sdk(path):
    path = path.resolve()
    settings = json.loads((path / "SDKSettings.json").read_text(encoding="utf-8"))
    sdk_version = settings.get("Version")
    if not isinstance(sdk_version, str) or not sdk_version:
        fail(str(path) + ": missing SDK Version")
    version(sdk_version)
    build_path = path / "System/Library/CoreServices/SystemVersion.plist"
    build = "unknown"
    if build_path.exists():
        build = plistlib.loads(build_path.read_bytes()).get("ProductBuildVersion", "unknown")
    if not isinstance(build, str) or not build:
        build = "unknown"
    return SDK(path, sdk_version, settings.get("CanonicalName", "unknown"), name(build))


def discover_sdks():
    roots = []
    suffix = "Platforms/MacOSX.platform/Developer/SDKs"
    if os.environ.get("DEVELOPER_DIR"):
        roots.append(Path(os.environ["DEVELOPER_DIR"]) / suffix)
    try:
        selected = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
        if selected.returncode == 0 and selected.stdout.strip():
            roots.append(Path(selected.stdout.strip()) / suffix)
    except OSError:
        pass
    roots.append(Path("/Library/Developer/CommandLineTools/SDKs"))
    roots.extend(path / "Contents/Developer" / suffix for path in Path("/Applications").glob("Xcode*.app"))
    paths = sorted({path.resolve() for root in roots for path in root.glob("*.sdk")})
    candidates = []
    for path in paths:
        if not any((path / "usr/lib/swift").glob("*.tbd")):
            print(f"swift-runtime-exports: candidate {path}: no Swift tbds; ignored", file=sys.stderr)
            continue
        try:
            sdk = read_sdk(path)
        except (AuditError, OSError, ValueError, plistlib.InvalidFileException) as error:
            print(f"swift-runtime-exports: candidate {path}: unreadable ({error}); ignored", file=sys.stderr)
            continue
        print(f"swift-runtime-exports: candidate {path}: {sdk.version} ({sdk.build})", file=sys.stderr)
        candidates.append(sdk)
    return sorted(candidates, key=SDK.key)


def choose_sdk(candidates):
    if not candidates:
        fail("no installed macOS SDK satisfies selection")
    sdk = candidates[0]
    print(f"swift-runtime-exports: chosen {sdk.path}: {sdk.version} ({sdk.build})", file=sys.stderr)
    return sdk


def scalar(text):
    text = text.strip()
    if text.startswith("'"):
        if not re.fullmatch(r"'(?:[^']|'')*'", text):
            fail("invalid single-quoted tbd scalar: " + text)
        return text[1:-1].replace("''", "'")
    if not text or any(char in text for char in "\n\r[]{}\""):
        fail("unsupported tbd scalar: " + repr(text))
    return text


def sequence(text):
    text = text.strip()
    if not (text.startswith("[") and text.endswith("]")):
        fail("expected tbd flow sequence: " + text)
    # Commas within single-quoted scalars are literal; YAML escapes a quote as ''.
    values = []
    token = []
    quoted = False
    for char in text[1:-1]:
        if char == "'":
            quoted = not quoted
        if char == "," and not quoted:
            if not "".join(token).strip():
                fail("empty tbd flow sequence item")
            values.append(scalar("".join(token)))
            token = []
        else:
            token.append(char)
    if quoted:
        fail("unterminated tbd quoted scalar")
    if "".join(token).strip():
        values.append(scalar("".join(token)))
    return values


def mapping_fields(lines, pattern):
    fields = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = pattern.fullmatch(line)
        if match:
            fields.append([match.group("key"), match.group("value"), bool(match.groupdict().get("item"))])
        elif fields and line[:1].isspace():
            fields[-1][1] += "\n" + line
        else:
            fail("unsupported tbd line: " + line)
    return fields


def export_blocks(text, allowed):
    pattern = re.compile(r"\s+(?P<item>-\s+)?(?P<key>[\w-]+):\s*(?P<value>.*)")
    blocks = []
    for key, value, new_item in mapping_fields(text.splitlines(), pattern):
        if key not in allowed:
            fail("unknown tbd item field: " + key)
        if new_item:
            blocks.append({})
        if not blocks or key in blocks[-1]:
            fail("missing item marker or duplicate tbd item field: " + key)
        blocks[-1][key] = sequence(value)
    for block in blocks:
        if "targets" not in block:
            fail("tbd export/reexport block has no targets")
    return blocks


@dataclass
class Library:
    arches: set = field(default_factory=set)
    symbols: dict = field(default_factory=lambda: {arch: set() for arch in ARCHES})
    reexports: dict = field(default_factory=lambda: {arch: set() for arch in ARCHES})


def target_arches(targets):
    return {TARGETS[target] for target in targets if target in TARGETS}


def add_document(lines, libraries):
    pattern = re.compile(r"(?P<key>[\w-]+):\s*(?P<value>.*)")
    fields = {}
    for key, value, _ in mapping_fields(lines, pattern):
        if key not in TOP_KEYS:
            fail("unknown tbd top-level key: " + key)
        if key in fields:
            fail("duplicate tbd top-level key: " + key)
        fields[key] = value
    if scalar(fields.get("tbd-version", "missing")) != "4":
        fail("only tbd-version 4 is supported")
    if not {"targets", "install-name"} <= fields.keys():
        fail("tbd document requires targets and install-name")
    lib = libraries.setdefault(library_name(scalar(fields["install-name"])), Library())
    lib.arches.update(target_arches(sequence(fields["targets"])))
    prefixes = {"objc-classes": ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"),
                "objc-eh-types": ("_OBJC_EHTYPE_$_",), "objc-ivars": ("_OBJC_IVAR_$_",)}
    for section in ("exports", "reexports", "reexported-libraries"):
        if section not in fields:
            continue
        allowed = {"targets", "libraries"} if section == "reexported-libraries" else EXPORT_KEYS
        for block in export_blocks(fields[section], allowed):
            arches = target_arches(block["targets"])
            for key, values in block.items():
                if key == "targets":
                    continue
                for value in values:
                    name(value)
                    if key == "libraries":
                        for arch in arches:
                            lib.reexports[arch].add(library_name(value))
                    elif not value.startswith("$ld$"):
                        for arch in arches:
                            lib.symbols[arch].update(prefix + value for prefix in prefixes.get(key, ("",)))


def parse_tbd(path, data, libraries):
    try:
        text = data.decode("utf-8")
        if text.lstrip().startswith(("{", "[")):
            fail("JSON/v5 tbd is unsupported; only tbd v4 YAML is supported")
        documents = []
        current = None
        for line in text.splitlines():
            if line == "--- !tapi-tbd":
                current = []
                documents.append(current)
            elif line == "...":
                current = None
            elif current is not None:
                current.append(line)
            elif line.strip() and not line.lstrip().startswith("#"):
                fail("expected --- !tapi-tbd (tbd v4 YAML)")
        if not documents:
            fail("no tbd v4 documents")
        for document in documents:
            add_document(document, libraries)
    except AuditError as error:
        fail(str(path) + ": " + str(error))


def combined_lines(entries):
    for value in sorted(set().union(*entries.values())):
        arches = [arch for arch in ARCHES if value in entries[arch]]
        yield ("*" if len(arches) == 2 else arches[0]) + " " + value


def generate(sdk):
    paths = sorted((sdk.path / "usr/lib/swift").glob("*.tbd"), key=lambda path: path.name)
    if not paths:
        fail(str(sdk.path) + ": no Swift tbds")
    libraries = {}
    source_hash = hashlib.sha256()
    for path in paths:
        data = path.read_bytes()
        source_hash.update(f"{path.name} {hashlib.sha256(data).hexdigest()}\n".encode("utf-8"))
        parse_tbd(path, data, libraries)
    sections = []
    symbol_count = 0
    for key, lib in sorted(libraries.items()):
        if not lib.arches:
            continue
        symbols = list(combined_lines(lib.symbols))
        edges = sorted("reexport " + line for line in combined_lines(lib.reexports))
        sections.append("\n".join(["[" + key + "]", *edges, *symbols]))
        symbol_count += len(symbols)
    header = ["# Peekaboo Swift runtime export baseline. Generated; do not edit.",
              "# Regenerate: python3 scripts/swift-runtime-exports.py generate --oldest-installed --output <this file>",
              "format: 1", "sdk: " + sdk.path.name, "sdk-version: " + sdk.version,
              "sdk-build: " + sdk.build, "architectures: " + " ".join(ARCHES),
              "source-sha256: " + source_hash.hexdigest(), "libraries: " + str(len(sections)),
              "symbols: " + str(symbol_count)]
    return ("\n".join(header) + "\n\n" + "\n\n".join(sections) + "\n").encode("utf-8")


def read_header(path):
    header = {}
    with path.open(encoding="utf-8") as source:
        for line in source:
            if line.startswith("#"):
                continue
            if not line.strip():
                break
            match = re.fullmatch(r"([a-z0-9-]+): (\S(?:.*\S)?)\n", line)
            if not match or match[1] not in HEADER_KEYS or match[1] in header:
                fail(str(path) + ": malformed baseline header: " + line.rstrip())
            header[match[1]] = match[2]
    if set(header) != set(HEADER_KEYS):
        fail(str(path) + ": incomplete baseline header")
    if header["format"] != "1":
        fail(str(path) + ": unknown baseline format: " + header["format"])
    version(header["sdk-version"])
    if (header["architectures"] != " ".join(ARCHES) or
            not re.fullmatch(r"[0-9a-f]{64}", header["source-sha256"]) or
            any(not re.fullmatch(r"[0-9]+", header[key]) for key in ("libraries", "symbols"))):
        fail(str(path) + ": malformed baseline header values")
    name(header["sdk"])
    name(header["sdk-build"])
    return header


def read_libraries(path, header):
    libraries = {}
    lib = None
    symbol_count = 0
    body = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line:
            body = True
            continue
        if not body or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            key = name(line[1:-1])
            if key in libraries:
                fail(str(path) + ": duplicate library: " + key)
            lib = Library()
            libraries[key] = lib
            continue
        parts = line.split(" ")
        edge = parts[0] == "reexport"
        if edge:
            parts = parts[1:]
        if lib is None or len(parts) != 2 or parts[0] not in (*ARCHES, "*"):
            fail(str(path) + ": malformed baseline line: " + line)
        arch_token, value = parts
        name(value)
        for arch in ARCHES if arch_token == "*" else (arch_token,):
            entries = lib.reexports if edge else lib.symbols
            if value in entries[arch]:
                fail(str(path) + ": duplicate baseline entry: " + line)
            entries[arch].add(value)
        symbol_count += not edge
    if len(libraries) != int(header["libraries"]) or symbol_count != int(header["symbols"]):
        fail(str(path) + ": baseline counts do not match header")
    return libraries


def check(sdk, path, header):
    expected = generate(sdk)
    actual = path.read_bytes()
    if actual == expected:
        print("Swift runtime baseline matches: " + str(path))
        return 0
    print("swift-runtime-exports: baseline differs: " + str(path), file=sys.stderr)
    new_header = dict(line.split(": ", 1) for line in expected.decode().split("\n\n", 1)[0].splitlines()
                      if not line.startswith("#"))
    for key in HEADER_KEYS:
        if header[key] != new_header[key]:
            print(f"  {key}: {header[key]} -> {new_header[key]}", file=sys.stderr)
    old_lines, new_lines = Counter(actual.splitlines()), Counter(expected.splitlines())
    print(f"  added lines: {sum((new_lines - old_lines).values())}; "
          f"removed lines: {sum((old_lines - new_lines).values())}", file=sys.stderr)
    return 1


def minimum_macos(binary, arch):
    output = run(["otool", "-arch", arch, "-l", binary])
    minima = []
    for command in re.split(r"(?m)^\s*cmd ", output)[1:]:
        kind = command.splitlines()[0].strip()
        if kind not in ("LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX"):
            continue
        fields = dict(re.findall(r"(?m)^\s*(platform|minos|version)\s+(\S+)\s*$", command))
        if kind == "LC_BUILD_VERSION" and fields.get("platform", "").lower() not in ("1", "macos"):
            fail(f"{binary}: {arch} LC_BUILD_VERSION platform is not macOS")
        value = fields.get("minos" if kind == "LC_BUILD_VERSION" else "version")
        if value is None:
            fail(f"{binary}: {arch} missing minimum macOS")
        version(value)
        minima.append(value)
    if not minima:
        fail(f"{binary}: {arch} missing minimum macOS load command")
    return max(minima, key=version)


def strong_imports(binary, arch):
    imports = set()
    for line in run(["nm", "-arch", arch, "-m", "-u", binary]).splitlines():
        match = NM_IMPORT.fullmatch(line)
        if not match:
            # Flat-namespace and dynamic-lookup imports name no source library, so they cannot be audited.
            if line.lstrip().startswith("(undefined"):
                fail(f"{binary}: {arch} unrecognized or unattributed undefined symbol: {line.strip()}")
            continue
        library = name(match["library"])
        if match["weak"] or not library.startswith("libswift") or library.startswith("libswiftCompatibility"):
            continue
        imports.add((library, match["symbol"]))
    return imports


def reachable(libraries, arch, root):
    visited = set()
    pending = [root]
    while pending:
        key = pending.pop()
        if key in visited:
            continue
        visited.add(key)
        lib = libraries.get(key)
        if lib is not None:
            pending.extend(lib.reexports[arch] - visited)
    return visited


def audit(directory, binary):
    baselines = []
    seen_versions = set()
    for path in sorted(directory.glob("*.exports")):
        header = read_header(path)
        sdk_version = version(header["sdk-version"])
        if sdk_version in seen_versions:
            fail(f"duplicate baseline version {header['sdk-version']} in {directory}")
        seen_versions.add(sdk_version)
        baselines.append((sdk_version, path, header))
    arches = run(["lipo", "-archs", binary]).split()
    if not arches or len(arches) != len(set(arches)) or any(arch not in ARCHES for arch in arches):
        fail(f"{binary}: unsupported or missing architectures: {' '.join(arches)}")
    minima = {arch: minimum_macos(binary, arch) for arch in sorted(arches)}
    minimum = max(minima.values(), key=version)
    candidates = sorted(item for item in baselines if item[0] >= version(minimum))
    if not candidates:
        fail(f"No Swift runtime baseline covers minimum macOS {minimum} in {directory}")
    _, path, header = candidates[0]
    libraries = read_libraries(path, header)
    missing = []
    counts = {}
    for arch in sorted(arches):
        imports = strong_imports(binary, arch)
        counts[arch] = len(imports)
        closure = {}
        for library, symbol in sorted(imports):
            if library not in closure:
                closure[library] = reachable(libraries, arch, library)
            if not any(key in libraries and symbol in libraries[key].symbols[arch] for key in closure[library]):
                missing.append((arch, library, symbol))
    identity = f"{header['sdk-version']} ({header['sdk-build']}, {header['sdk']})"
    if missing:
        print(f"Strong Swift runtime imports missing from macOS {header['sdk-version']} baseline "
              f"({header['sdk-build']}, {header['sdk']}): {binary}", file=sys.stderr)
        for item in sorted(missing):
            print("  " + " ".join(item), file=sys.stderr)
        return 1
    print(f"Swift runtime baseline: macOS {identity} from {path}")
    for arch in sorted(arches):
        print(f"Swift runtime imports verified: {arch} minimum macOS {minima[arch]}, "
              f"{counts[arch]} strong libswift imports")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    generator = commands.add_parser("generate", help="generate a normalized SDK baseline")
    source = generator.add_mutually_exclusive_group(required=True)
    source.add_argument("--sdk", type=Path)
    source.add_argument("--oldest-installed", action="store_true")
    generator.add_argument("--minimum-version", default="15.0")
    generator.add_argument("--output", type=Path, required=True)
    checker = commands.add_parser("check", help="compare a baseline byte-for-byte with an SDK")
    source = checker.add_mutually_exclusive_group(required=True)
    source.add_argument("--sdk", type=Path)
    source.add_argument("--installed", action="store_true")
    checker.add_argument("--baseline", type=Path, required=True)
    auditor = commands.add_parser("audit", help="audit strong Swift runtime imports without executing a binary")
    auditor.add_argument("--baseline-dir", type=Path, required=True)
    auditor.add_argument("binary", type=Path)
    options = parser.parse_args()
    if options.command == "generate":
        minimum = version(options.minimum_version)
        sdk = read_sdk(options.sdk) if options.sdk else choose_sdk(
            [sdk for sdk in discover_sdks() if version(sdk.version) >= minimum])
        content = generate(sdk)
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_bytes(content)
        print("Swift runtime baseline generated: " + str(options.output))
        return 0
    if options.command == "check":
        header = read_header(options.baseline)
        if options.sdk:
            sdk = read_sdk(options.sdk)
        else:
            candidates = [sdk for sdk in discover_sdks() if version(sdk.version) == version(header["sdk-version"])
                          and sdk.build == header["sdk-build"]]
            if not candidates:
                print(f"swift-runtime-exports: no installed SDK matches {header['sdk']} "
                      f"{header['sdk-version']} ({header['sdk-build']}); skipped")
                return 0
            sdk = choose_sdk(candidates)
        return check(sdk, options.baseline, header)
    return audit(options.baseline_dir, options.binary)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AuditError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print("swift-runtime-exports: " + str(error), file=sys.stderr)
        sys.exit(1)
