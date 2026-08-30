#!/usr/bin/env python3
"""Offline contracts, plus opt-in compilation of inert real-submodule fixtures; no test discovery."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET


SOURCE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("workspace", SOURCE / "setup-swift-workspace.py")
workspace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workspace)

FAKE_GIT = r'''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
root = os.environ['FIXTURE_ROOT']
cwd = root
if args[:1] == ['-C']:
    cwd, args = args[1], args[2:]
module = Path(cwd).name
revision = 'a' * 40 if module == 'Commander' else 'b' * 40
if args == ['rev-parse', '--show-toplevel']:
    print(root if os.environ.get('PARENT_FALLBACK') else cwd)
elif args == ['rev-parse', 'HEAD']:
    print(('d' * 40 if os.environ.get('WRONG_HEAD') else revision) if cwd != root else 'c' * 40)
elif args[:2] == ['ls-tree', 'HEAD']:
    module = args[-1]
    if os.environ.get('MISSING_LINK') != module:
        mode = '100644 blob' if os.environ.get('WRONG_LINK') else '160000 commit'
        print(mode + ' ' + ('a' * 40 if module == 'Commander' else 'b' * 40) + '\t' + module)
elif args[:1] == ['config']:
    key = args[-1]
    module = key.split('.')[1]
    if key.endswith('.path'): print(module)
    elif os.environ.get('WRONG_IDENTITY'): print('synthetic-unexpected-origin')
    else: print('https://github.com/' + ('steipete' if module == 'Commander' else 'openclaw') + '/' + module + '.git')
elif args[:1] == ['status']:
    if os.environ.get('DIRTY_SOURCE') or (Path(root) / 'fixture-dirty').exists(): print(' M fixture')
else:
    sys.exit(91)
'''


class WorkspaceFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="peekaboo workspace contracts ")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "checkout with spaces"
        (self.root / "scripts").mkdir(parents=True)
        for name in ("setup-swift-workspace.py", "source-provenance.sh"):
            shutil.copyfile(SOURCE / name, self.root / "scripts" / name)
        for package in (*workspace.PACKAGES, "Commander", "AXorcist"):
            (self.root / package).mkdir(parents=True)
            (self.root / package / "Package.swift").touch()
        for module in ("Commander", "AXorcist"):
            (self.root / module / ".git").mkdir()
        (self.root / ".gitmodules").touch()
        for project in workspace.WORKSPACES:
            (self.root / project).mkdir(parents=True)
            (self.root / project / "contents.xcworkspacedata").touch()
        self.bin = self.base / "fake tools"
        self.bin.mkdir()
        (self.bin / "git").write_text(FAKE_GIT)
        (self.bin / "git").chmod(0o755)
        self.env = {"PATH": str(self.bin) + ":" + str(Path(sys.executable).parent) + ":/usr/bin:/bin",
                    "FIXTURE_ROOT": str(self.root), "HOME": str(self.base / "home")}

    def run_setup(self, *args, ok=True, extra=None):
        result = subprocess.run([sys.executable, str(self.root / "scripts/setup-swift-workspace.py"), *args],
                                env=self.env | (extra or {}), capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        return result


class WorkspaceContract(WorkspaceFixture):
    def test_clean_setup_idempotence_and_remove_preserve_unrelated_settings(self):
        other = self.root / "Apps/CLI/.swiftpm/configuration/registries.json"
        other.parent.mkdir(parents=True)
        other.write_bytes(b'opaque operator settings; never parse or rewrite\n')
        self.run_setup("check", ok=False)
        self.run_setup("setup")
        before = {p: (self.root / p).read_bytes() for p in workspace.CONFIGS}
        self.run_setup("setup")
        self.run_setup("check", "--release")
        self.assertEqual(before, {p: (self.root / p).read_bytes() for p in workspace.CONFIGS})
        for content in before.values():
            self.assertEqual(json.loads(content)["object"],
                             [{"original": workspace.REMOTE, "mirror": (self.root / "Commander").as_uri()}])
        self.run_setup("remove")
        self.assertTrue(all(not (self.root / p).exists() for p in workspace.CONFIGS))
        self.assertEqual(other.read_bytes(), b'opaque operator settings; never parse or rewrite\n')

    def test_relocation_requires_explicit_setup(self):
        self.run_setup("setup")
        old_root = self.root
        self.root = self.base / "relocated checkout"
        old_root.rename(self.root)
        self.env["FIXTURE_ROOT"] = str(self.root)
        self.run_setup("check", ok=False)
        self.run_setup("setup")
        self.run_setup("check")
        self.assertNotIn(str(old_root), (self.root / workspace.MIRROR).read_text())

    def test_unowned_conflict_is_not_read_or_overwritten(self):
        path = self.root / workspace.CONFIGS[-1]
        path.parent.mkdir(parents=True)
        path.write_bytes(b'credential-bearing opaque user configuration')
        result = self.run_setup("setup", ok=False)
        self.assertNotIn("credential-bearing", result.stderr)
        self.assertEqual(path.read_bytes(), b'credential-bearing opaque user configuration')
        self.assertFalse((self.root / workspace.STATE).exists())
        self.assertFalse((self.root / workspace.CONFIGS[1]).exists())

    def test_owned_tampering_and_symlinks_fail_closed(self):
        self.run_setup("setup")
        path = self.root / workspace.CONFIGS[1]
        original = path.read_bytes()
        path.write_bytes(b'unknown mirror')
        for action in ("setup", "check", "remove"):
            self.run_setup(action, ok=False)
            self.assertEqual(path.read_bytes(), b'unknown mirror')
        path.unlink()
        outside = self.base / "outside"
        outside.write_bytes(original)
        path.symlink_to(outside)
        self.run_setup("setup", ok=False)
        self.assertEqual(outside.read_bytes(), original)

    def test_symlinked_parent_and_hardlink_fail_closed(self):
        outside = self.base / "outside"
        outside.mkdir()
        (self.root / "Apps/CLI/.swiftpm").symlink_to(outside)
        self.run_setup("setup", ok=False)
        self.assertEqual(list(outside.iterdir()), [])
        (self.root / "Apps/CLI/.swiftpm").unlink()
        self.run_setup("setup")
        os.link(self.root / workspace.CONFIGS[1], outside / "hardlink")
        self.run_setup("setup", ok=False)

    def test_missing_wrong_uninitialized_or_aliased_submodule(self):
        for extra in ({"MISSING_LINK": "Commander"}, {"MISSING_LINK": "AXorcist"},
                      {"WRONG_HEAD": "1"}, {"WRONG_LINK": "1"}, {"WRONG_IDENTITY": "1"},
                      {"PARENT_FALLBACK": "1"}):
            self.run_setup("setup", extra=extra, ok=False)
            self.assertFalse((self.root / workspace.STATE).exists())
        (self.root / "Commander/.git").rmdir()
        self.run_setup("setup", ok=False)

    def test_release_source_gate_and_child_failure(self):
        command = [sys.executable, "-c", "raise SystemExit(37)"]
        self.assertEqual(self.run_setup("run", "--release", "--", *command, ok=False).returncode, 37)
        sentinel = self.base / "ran"
        command = [sys.executable, "-c", "from pathlib import Path; Path(" + repr(str(sentinel)) + ").touch()"]
        self.run_setup("run", "--release", "--", *command, extra={"DIRTY_SOURCE": "1"}, ok=False)
        self.assertFalse(sentinel.exists())
        command = [sys.executable, "-c", "from pathlib import Path; Path(" +
                   repr(str(self.root / "fixture-dirty")) + ").touch()"]
        self.run_setup("run", "--release", "--", *command, ok=False)

    def test_effective_mapping_strict_arguments_and_post_build_integrity(self):
        probe = self.base / "fake swift.py"
        probe.write_text('''import json, os, sys
from pathlib import Path
p = Path(os.environ['SWIFTPM_MIRROR_CONFIG'])
assert json.loads(p.read_text())['object'][0]['mirror'] == (Path(os.environ['FIXTURE_ROOT']) / 'Commander').as_uri()
assert sys.argv[1:] == ['build', '--only-use-versions-from-resolved-file', '--scratch-path', 'fresh scratch']
if os.environ.get('MUTATE_MAPPING'): p.write_text('tampered')
''')
        command = [sys.executable, str(probe), "build", "--only-use-versions-from-resolved-file",
                   "--scratch-path", "fresh scratch"]
        self.run_setup("run", "--release", "--", *command)
        self.run_setup("run", "--release", "--", *command, extra={"MUTATE_MAPPING": "1"}, ok=False)

    def test_inherited_override_is_rejected_without_reading_it(self):
        result = self.run_setup("setup", extra={"SWIFTPM_MIRROR_CONFIG": "private-value"}, ok=False)
        self.assertNotIn("private-value", result.stderr)
        self.assertFalse((self.root / workspace.STATE).exists())
        result = self.run_setup("setup", extra={"GIT_WORK_TREE": "private-value"}, ok=False)
        self.assertNotIn("private-value", result.stderr)

    def test_build_child_retains_callers_file_creation_permissions(self):
        previous = os.umask(0o027)
        try:
            self.run_setup("run", "--", sys.executable, "-c", "import os; assert os.umask(0) == 0o027")
        finally:
            os.umask(previous)

    def test_xcode_contexts_do_not_promote_commander_to_a_root_package(self):
        root = SOURCE.parent
        document = ET.parse(root / workspace.WORKSPACES[0] / "contents.xcworkspacedata")
        self.assertEqual(document.findall(".//FileRef[@location='group:../Commander']"), [])
        for context in workspace.WORKSPACES[1:]:
            project = (root / context).parent / "project.pbxproj"
            content = project.read_text()
            self.assertNotRegex(content, r'isa = PBXFileReference;[^\n]*path = ../../Commander;')


@unittest.skipUnless(os.environ.get("PEEKABOO_TEST_REAL_SWIFT_WORKSPACE") == "1",
                     "opt in to compile-only SwiftPM/Xcode inert fixtures")
class RealSubmoduleContract(WorkspaceFixture):
    def setUp(self):
        super().setUp()
        self.env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.base / "home"),
            "TMPDIR": str(self.base),
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
            "GIT_AUTHOR_NAME": "Inert Fixture", "GIT_COMMITTER_NAME": "Inert Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        if "DEVELOPER_DIR" in os.environ:
            self.env["DEVELOPER_DIR"] = os.environ["DEVELOPER_DIR"]
        Path(self.env["HOME"]).mkdir()
        self.git(self.root, "init", "-q")
        for module in ("Commander", "AXorcist"):
            seed = self.base / (module + " seed")
            (self.root / module).rename(seed)
            sources = seed / "Sources" / module
            sources.mkdir(parents=True)
            if module == "Commander":
                dependencies = ""
                target_dependencies = ""
                source = "public enum Value { public static let committed = 1 }\n"
            else:
                dependencies = ('dependencies: [.package(url: "' + workspace.REMOTE + '", exact: "0.2.4")], ')
                target_dependencies = ', dependencies: [.product(name: "Commander", package: "Commander")]'
                source = "import Commander\npublic let viaAXorcist = Value.committed\n"
            (seed / "Package.swift").write_text(
                '// swift-tools-version: 6.2\nimport PackageDescription\n'
                'let package = Package(name: "' + module + '", products: [.library(name: "' + module +
                '", targets: ["' + module + '"])], ' + dependencies + 'targets: [.target(name: "' + module +
                '"' + target_dependencies + ')])\n')
            (sources / (module + ".swift")).write_text(source)
            self.git(seed, "init", "-q")
            self.git(seed, "add", ".")
            self.git(seed, "-c", "commit.gpgsign=false", "commit", "-qm", "Inert fixture")
            self.git(seed, "tag", "0.2.4")
            self.git(self.root, "-c", "protocol.file.allow=always", "submodule", "add", str(seed), module)
            url = workspace.REMOTE if module == "Commander" else "https://github.com/openclaw/AXorcist.git"
            self.git(self.root, "config", "--file", ".gitmodules", "submodule." + module + ".url", url)
            self.assertTrue((self.root / module / ".git").is_file())
        (self.root / ".gitignore").write_text("**/.swiftpm/\n**/Package.resolved\n**/xcuserdata/\n")
        consumer = self.root / "Apps/CLI"
        (consumer / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Fixture", products: [.library(name: "Consumer", targets: ["Consumer"])],
    dependencies: [.package(path: "../../Commander"), .package(path: "../../AXorcist")],
    targets: [.target(name: "Consumer", dependencies: [.product(name: "Commander", package: "Commander"),
        .product(name: "AXorcist", package: "AXorcist")])])
''')
        (consumer / "Sources/Consumer").mkdir(parents=True)
        (consumer / "Sources/Consumer/Consumer.swift").write_text(
            "import Commander\nimport AXorcist\npublic let consumer = Value.liveOnly + viaAXorcist\n")
        (self.root / workspace.WORKSPACES[0] / "contents.xcworkspacedata").write_text(
            '<?xml version="1.0"?><Workspace version="1.0"><FileRef location="group:CLI"/></Workspace>')
        self.git(self.root, "add", ".")
        self.git(self.root, "-c", "commit.gpgsign=false", "commit", "-qm", "Inert consumer")
        # Only the live working copy has this symbol; a tagged checkout cannot compile the consumer.
        self.live = self.root / "Commander/Sources/Commander/Commander.swift"
        self.live.write_text("public enum Value { public static let committed = 1; public static let liveOnly = 2 }\n")

    def command(self, args, cwd=None):
        start = time.monotonic()
        result = subprocess.run(args, cwd=cwd or self.root, env=self.env, capture_output=True, text=True)
        print(json.dumps({"argv": args, "cwd": str(cwd or self.root), "exit": result.returncode,
                          "seconds": time.monotonic() - start}), flush=True)
        print(result.stdout, end="", flush=True)
        print(result.stderr, end="", file=sys.stderr, flush=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def git(self, cwd, *args):
        return self.command(["/usr/bin/git", *args], cwd)

    def test_gitfile_live_source_with_strict_swiftpm_and_xcode(self):
        before = self.live.read_bytes()
        scratch = self.base / "swift-build"
        swift = ["/usr/bin/xcrun", "swift", "build", "--package-path", str(self.root / "Apps/CLI"),
                 "--scratch-path", str(scratch), "--cache-path", str(self.base / "cache"),
                 "--config-path", str(self.base / "config"), "--security-path", str(self.base / "security"),
                 "--disable-keychain", "--disable-netrc", "--only-use-versions-from-resolved-file", "--jobs", "4"]
        runner = [sys.executable, str(self.root / "scripts/setup-swift-workspace.py"), "run", "--"]
        result = self.command(runner + swift)
        state = json.loads((scratch / "workspace-state.json").read_text())["object"]["dependencies"]
        commander = [d for d in state if d["packageRef"]["identity"] == "commander"]
        self.assertEqual(len(commander), 1)
        self.assertEqual(commander[0]["packageRef"]["kind"], "fileSystem")
        self.assertEqual(commander[0]["packageRef"]["location"], str(self.root / "Commander"))
        self.assertTrue(list(scratch.rglob("Consumer.o")))
        self.assertNotIn("conflict", (result.stdout + result.stderr).lower())
        derived = self.base / "derived"
        result = self.command(runner + ["/usr/bin/xcodebuild", "-workspace",
            str(self.root / workspace.WORKSPACES[0]), "-scheme", "Consumer", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived),
            "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
            "-disablePackageRepositoryCache", "-packageAuthorizationProvider", "netrc", "-scmProvider", "system",
            "-jobs", "4", "build", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="])
        self.assertNotIn("conflict", (result.stdout + result.stderr).lower())
        self.assertTrue(list(derived.rglob("Consumer.o")))
        self.assertEqual(self.live.read_bytes(), before)
        self.assertEqual(list(self.root.rglob("Package.resolved")), [])
        self.run_setup("check")


if __name__ == "__main__":
    unittest.main()
