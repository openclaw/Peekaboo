#!/usr/bin/env python3
"""Audit strong Swift runtime imports against an installed macOS SDK's tbds.

Choose the oldest SDK at or above the binary's highest slice minimum macOS,
but older than BASELINE_MUST_PREDATE. Parse all Swift tbd v4 files in-process,
following per-architecture re-exports, and record the SDK and export digest.
Fail closed when no SDK is eligible, parsing or inspection is unsupported,
or any strong Swift runtime import is missing. Never execute the binary.
"""

import argparse
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
# Newest runtime refused as an audit floor: #831 was a macOS 27-only symbol.
# Raise deliberately only when no older SDK can be provisioned on release hosts.
BASELINE_MUST_PREDATE = (27,)
TOP_KEYS = set("""tbd-version targets uuids flags install-name current-version compatibility-version
    swift-abi-version parent-umbrella allowable-clients reexported-libraries exports reexports
    undefineds rpaths""".split())
EXPORT_KEYS = set("""targets symbols weak-symbols thread-local-symbols objc-classes objc-eh-types
    objc-ivars""".split())
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


def discover_sdks(roots=None):
    if roots is None:
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


def choose_sdk(candidates, minimum):
    limit = ".".join(str(part) for part in BASELINE_MUST_PREDATE)
    eligible = []
    for sdk in candidates:
        reasons = []
        if version(sdk.version) < version(minimum):
            reasons.append(f"below minimum macOS {minimum}")
        if version(sdk.version) >= BASELINE_MUST_PREDATE:
            reasons.append(f"not older than macOS {limit}")
        if reasons:
            print(f"swift-runtime-exports: candidate {sdk.path}: ineligible ({'; '.join(reasons)})",
                  file=sys.stderr)
        else:
            eligible.append(sdk)
    if not eligible:
        fail(f"No eligible macOS SDK for the Swift runtime audit: minimum macOS {minimum}, "
             f"SDK must predate macOS {limit}; install Command Line Tools or an Xcode that provides "
             f"a macOS SDK older than {limit} (for example the macOS 26 SDK)")
    sdk = min(eligible, key=SDK.key)
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
            fields.append((match.group("key"), [match.group("value")], bool(match.groupdict().get("item"))))
        elif fields and line[:1].isspace():
            # Collect continuation lines and join once; repeated string concatenation is quadratic.
            fields[-1][1].append(line)
        else:
            fail("unsupported tbd line: " + line)
    return [(key, "\n".join(value), item) for key, value, item in fields]


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


def sdk_exports(sdk):
    paths = sorted((sdk.path / "usr/lib/swift").glob("*.tbd"), key=lambda path: path.name)
    if not paths:
        fail(str(sdk.path) + ": no Swift tbds")
    libraries = {}
    source_hash = hashlib.sha256()
    for path in paths:
        data = path.read_bytes()
        source_hash.update(f"{path.name} {hashlib.sha256(data).hexdigest()}\n".encode("utf-8"))
        parse_tbd(path, data, libraries)
    return libraries, source_hash.hexdigest()


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


def audit(roots, binary):
    arches = run(["lipo", "-archs", binary]).split()
    if not arches or len(arches) != len(set(arches)) or any(arch not in ARCHES for arch in arches):
        fail(f"{binary}: unsupported or missing architectures: {' '.join(arches)}")
    minima = {arch: minimum_macos(binary, arch) for arch in sorted(arches)}
    minimum = max(minima.values(), key=version)
    sdk = choose_sdk(discover_sdks(roots), minimum)
    libraries, source_hash = sdk_exports(sdk)
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
    if missing:
        print(f"Strong Swift runtime imports missing from macOS {sdk.version} SDK "
              f"({sdk.build}, {sdk.path.name}): {binary}", file=sys.stderr)
        for item in sorted(missing):
            print("  " + " ".join(item), file=sys.stderr)
        return 1
    print(f"Swift runtime baseline: macOS {sdk.version} ({sdk.build}) {sdk.path} sha256:{source_hash}")
    for arch in sorted(arches):
        print(f"Swift runtime imports verified: {arch} minimum macOS {minima[arch]}, "
              f"{counts[arch]} strong libswift imports")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    auditor = commands.add_parser("audit", help="audit strong Swift runtime imports without executing a binary")
    auditor.add_argument("--sdk-root", type=Path, action="append",
                         help="SDK discovery directory; repeatable, replaces default discovery roots")
    auditor.add_argument("binary", type=Path)
    options = parser.parse_args()
    return audit(options.sdk_root, options.binary)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AuditError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print("swift-runtime-exports: " + str(error), file=sys.stderr)
        sys.exit(1)
