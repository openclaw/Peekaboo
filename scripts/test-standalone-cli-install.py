#!/usr/bin/env python3
"""Verify the standalone installer with a native executable and companion dylib."""
import os
from pathlib import Path
import resource
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    assert result.returncode == 0, (command, result.returncode, result.stderr)
    return result


with tempfile.TemporaryDirectory(prefix="peekaboo-standalone-install.") as directory:
    fixture = Path(directory)
    scripts = fixture / "scripts"
    scripts.mkdir()
    cli = fixture / "Apps/CLI"
    output = cli / ".build/release"
    output.mkdir(parents=True)
    installed = fixture / "installed"
    installed.mkdir()
    tools = fixture / "tools"
    tools.mkdir()
    shutil.copy2(ROOT / "scripts/build-cli-standalone.sh", scripts / "build-cli-standalone.sh")
    # Compilation is controlled here; no Swift workspace or installed host app is changed.
    (scripts / "setup-swift-workspace.py").write_text("# Fixture build already completed.\n")
    library_source = fixture / "library.c"
    library_source.write_text("int companion_value(void) { return 42; }\n")
    library = output / "libswiftCompatibilityFixture.dylib"
    run(["/usr/bin/clang", "-dynamiclib", str(library_source), "-o", str(library),
         "-Wl,-install_name,@rpath/" + library.name])
    sdk_library = fixture / "sdk-library.dylib"
    shutil.move(library, sdk_library)
    collector = scripts / "copy-swift-runtime-libraries.sh"
    collector.write_text('#!/bin/bash\nset -eu\n'
                         'cp "$FIXTURE_SDK_LIBRARY" "$2/libswiftCompatibilityFixture.dylib"\n')
    collector.chmod(0o755)
    # Link with the same companion, then let the public builder collect it from
    # the controlled SDK fixture. This does not validate real Swift SDK scanning.
    shutil.copy2(sdk_library, library)
    binary_source = fixture / "binary.c"
    binary_source.write_text('#include <stdio.h>\nextern int companion_value(void);\n'
                             'int main(void) { printf("loaded=%d\\n", companion_value()); return 0; }\n')
    binary = output / "peekaboo"
    run(["/usr/bin/clang", str(binary_source), "-L" + str(output),
         "-lswiftCompatibilityFixture", "-Wl,-rpath,@executable_path", "-o", str(binary)])
    assert run([str(binary)]).stdout == "loaded=42\n"
    library.unlink()
    # Redirect only sudo's documented destination into this owned fixture. The
    # actual cp/install and installed Mach-O executable still run natively.
    sudo = tools / "sudo"
    sudo.write_text(f'#!{sys.executable}\n' + '''import os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] in ("cp", "install"), args
assert args[-1] in ("/usr/local/bin", "/usr/local/bin/", "/usr/local/bin/peekaboo"), args
original = args[-1]
args[-1] = os.environ["FIXTURE_INSTALL_DIR"]
if original.endswith("/peekaboo"):
    args[-1] = str(Path(args[-1]) / "peekaboo")
os.execv({"cp": "/bin/cp", "install": "/usr/bin/install"}[args[0]], args)
''')
    sudo.chmod(0o755)
    (tools / "python3").symlink_to(sys.executable)
    environment = dict(os.environ, PATH=f"{tools}:/usr/bin:/bin", FIXTURE_INSTALL_DIR=str(installed),
                       FIXTURE_SDK_LIBRARY=str(sdk_library))
    run(["/bin/bash", str(scripts / "build-cli-standalone.sh"), "--install"], env=environment)

    def no_core_dump():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    result = subprocess.run([str(installed / "peekaboo")], capture_output=True, text=True,
                            preexec_fn=no_core_dump)
    assert result.returncode == 0, f"installed executable cannot load companion: {result.stderr}"
    assert result.stdout == "loaded=42\n"
    assert (installed / library.name).read_bytes() == library.read_bytes()
    print("PASS actual standalone installer: native dylib dependency loads from owned installation")

    # A failed SDK collection must stop before any installation takes place.
    for path in installed.iterdir():
        path.unlink()
    collector.write_text("#!/bin/bash\nexit 19\n")
    failed = subprocess.run(["/bin/bash", str(scripts / "build-cli-standalone.sh"), "--install"],
                            env=environment, capture_output=True, text=True)
    assert failed.returncode == 19, failed.stderr
    assert not list(installed.iterdir()), "failed runtime collection must not install a partial CLI"

    # Toolchains with no compatibility dependencies still install normally.
    binary_source.write_text('#include <stdio.h>\nint main(void) { puts("independent"); return 0; }\n')
    run(["/usr/bin/clang", str(binary_source), "-o", str(binary)])
    library.unlink()
    collector.write_text("#!/bin/bash\nexit 0\n")
    run(["/bin/bash", str(scripts / "build-cli-standalone.sh"), "--install"], env=environment)
    assert run([str(installed / "peekaboo")]).stdout == "independent\n"
    assert [path.name for path in installed.iterdir()] == ["peekaboo"]
    print("PASS collection failure refuses partial installation; native dependency-free CLI still installs")
