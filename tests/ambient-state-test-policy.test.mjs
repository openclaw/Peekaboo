import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));
const seeEnvironmentIDs = [
  "CLIAutomationTests.SeeCommandRuntimeTests/`config environment restores inherited values`(werePresent:)",
  "CLIAutomationTests.SeeCommandRuntimeTests/`config environment restores nested throwing bodies`()",
];
const unrelatedSeeIDs = [
  "CLIAutomationTests.SeeCommandRuntimeTests/unsafeRuntime()",
  "CoreCLITests.AppCommandLaunchFlowTests/launch()",
  "CoreCLITests.InteractionMutationInvalidatorTests/`Remote-selected local mutation installs a caller barrier`()",
  "CoreCLITests.InteractionMutationInvalidatorTests/`Remote coordinator rejects a host observation certificate that forbids preservation`()",
  `${seeEnvironmentIDs[0]}Extra`,
];
const packageJSON = JSON.parse(readFileSync(`${repositoryRoot}/package.json`, "utf8"));
const runtimeTests = readFileSync(
  `${repositoryRoot}/Apps/CLI/Tests/CLIRuntimeTests/CLIRuntimeSmokeTests.swift`,
  "utf8",
);

test("safe suite forces ambient-state tests off", () => {
  assert.match(
    packageJSON.scripts["test:safe"],
    /PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS=false swift test/,
  );
});

test("ambient-state tests require the exact shared opt-in", () => {
  assert.match(
    runtimeTests,
    /environment\["PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS"\] == "true"/,
  );
  assert.match(
    runtimeTests,
    /@Test\(\.enabled\(if: CLIRuntimeEnvironment\.runAmbientStateTests\)\)/,
  );
});

test("hosted See proof retains target inclusion without opting into ambient tests", () => {
  const manifest = readFileSync(`${repositoryRoot}/Apps/CLI/Package.swift`, "utf8");
  const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
  const step = workflow.split("      - name: Run See configuration environment regressions\n")[1]
    .split("\n  tachikoma:")[0];
  assert.match(step, /PEEKABOO_INCLUDE_AUTOMATION_TESTS: "true"/);
  assert.match(step, /PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS: "false"/);
  assert.match(step, /PEEKABOO_CONFIG_DISABLE_MIGRATION: "1"/);
  assert.match(step, /python3 ..\/..\/scripts\/test-see-config-environment.py/);
  assert.match(manifest, /if includeAutomationTests \{[\s\S]*name: "CLIAutomationTests"/);
  const target = manifest.split('name: "CLIAutomationTests"')[1].split("let package = Package(")[0];
  assert.doesNotMatch(target, /\b(?:exclude|sources):/);
  assert.doesNotMatch(manifest, /PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS/);
});

test("See environment proof uses declaration IDs, including backticks and argument labels", () => {
  const oldSelection = /SeeCommandRuntimeTests\/config environment restores (inherited values|nested throwing bodies)/;
  assert.ok(seeEnvironmentIDs.every((id) => !oldSelection.test(id)), "The old display-name filter discovers neither ID");
  const source = readFileSync(`${repositoryRoot}/Apps/CLI/Tests/CLIAutomationTests/SeeCommandTests.swift`, "utf8");
  assert.match(source, /@Test\(arguments: \[false, true\]\)\s+@MainActor\s+func `config environment restores inherited values`\(werePresent: Bool\)/);
  assert.match(source, /@Test\s+@MainActor\s+func `config environment restores nested throwing bodies`\(\)/);
  const regressions = source.split("struct SeeCommandRuntimeTests {")[1]
    .split("func `tree only See propagates")[0];
  assert.match(regressions, /resetConfiguration: \{ resets.append\(SeeConfigEnvironment\(\)\) \}/);
  assert.doesNotMatch(regressions, /ConfigurationManager|InProcessCommandRunner|executePeekabooCLI/);
});

function runSeeProofFixture(mode, hosted = true) {
  const directory = mkdtempSync(join(tmpdir(), "peekaboo-see-proof-"));
  try {
    const bin = join(directory, "bin");
    mkdirSync(bin);
    const calls = join(directory, "calls.jsonl");
    // Never discover or execute the real Swift tests on the operator's machine.
    writeFileSync(join(bin, "swift"), `#!/usr/bin/env python3
import json, os, sys
with open(os.environ["SEE_PROOF_CALLS"], "a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
mode = os.environ["SEE_PROOF_SCENARIO"]
ids = ${JSON.stringify(seeEnvironmentIDs)}
if sys.argv[1:3] == ["test", "list"]:
    if mode in ["zero-discovery", "no-selected-id"]: ids = []
    if mode == "missing-id": ids.pop()
    if mode == "duplicate-id": ids.append(ids[0])
    if mode == "extra-selected-id": ids.append(ids[0] + "/SeeCommandTests.swift:1:1")
    if mode == "display-id": ids[0] = "CLIAutomationTests.SeeCommandRuntimeTests/config environment restores inherited values"
    if mode not in ["selected-only", "zero-discovery"]: ids += ${JSON.stringify(unrelatedSeeIDs)}
    print("Building for debugging...")
    print("\\n".join(ids))
    sys.exit(1 if mode == "discovery-failed" else 0)
lines = [
    '◇ Test case passing 1 argument werePresent → false to "config environment restores inherited values" started.',
    '◇ Test case passing 1 argument werePresent → true to "config environment restores inherited values" started.',
    '✔ Test "config environment restores inherited values" with 2 test cases passed after 0.001 seconds.',
    '✔ Test "config environment restores nested throwing bodies" passed after 0.001 seconds.',
    '✔ Test run with 2 tests in 1 suite passed after 0.003 seconds.',
]
if mode == "plain-pass-format": lines[2] = lines[2].replace(" with 2 test cases", "")
if mode == "wrong-parameter-count": lines[2] = lines[2].replace("with 2 test cases", "with 3 test cases")
if mode == "zero-execution": lines = ['✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.']
if mode == "missing-summary": lines.pop()
if mode == "duplicate-summary": lines.append(lines[-1])
if mode == "wrong-count": lines[-1] = '✔ Test run with 3 tests in 1 suite passed after 0.003 seconds.'
if mode == "missing-pass": lines.pop(3)
if mode == "extra-pass": lines.insert(4, '✔ Test "unsafeRuntime" passed after 0.001 seconds.')
if mode == "missing-argument": lines.pop(1)
if mode == "duplicate-argument": lines.insert(1, lines[0])
print("\\n".join(lines))
sys.exit(1 if mode == "execution-failed" else 0)
`, { mode: 0o755 });
    const result = spawnSync("python3", [join(repositoryRoot, "scripts/test-see-config-environment.py")], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        GITHUB_ACTIONS: hosted ? "true" : "false",
        RUNNER_ENVIRONMENT: hosted ? "github-hosted" : "self-hosted",
        PEEKABOO_INCLUDE_AUTOMATION_TESTS: "true",
        PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS: "false",
        PEEKABOO_CONFIG_DISABLE_MIGRATION: "1",
        SEE_PROOF_CALLS: calls,
        SEE_PROOF_SCENARIO: mode,
      },
    });
    const invocations = hosted ? readFileSync(calls, "utf8").trim().split("\n").map(JSON.parse) : [];
    return { ...result, invocations };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("hosted See proof selects two declarations from global discovery and executes only those nonparallel", () => {
  const result = runSeeProofFixture("passed");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.invocations.length, 2);
  assert.deepEqual(result.invocations[0], [
    "test", "list", "--disable-xctest", "--enable-swift-testing", "-Xswiftc", "-DPEEKABOO_SKIP_AUTOMATION",
  ]);
  const execution = result.invocations[1];
  const filter = execution[execution.indexOf("--filter") + 1];
  assert.deepEqual(execution, [
    "test", "--disable-xctest", "--enable-swift-testing", "-Xswiftc", "-DPEEKABOO_SKIP_AUTOMATION",
    "--skip-build", "--no-parallel", "--filter", filter,
  ]);
  const selection = new RegExp(filter);
  for (const id of seeEnvironmentIDs) assert.ok(selection.test(id), id);
  for (const id of unrelatedSeeIDs) assert.ok(!selection.test(id), id);
  assert.match(result.stdout, /Verified discovery: 2 selected See environment test declarations from the global listing/);
  assert.match(result.stdout, /Verified execution: 2 tests in 1 suite/);
  // A package containing only the selected IDs is also valid; it is not required.
  const selectedOnly = runSeeProofFixture("selected-only");
  assert.equal(selectedOnly.status, 0, selectedOnly.stderr);
  const plain = runSeeProofFixture("plain-pass-format");
  assert.equal(plain.status, 0, plain.stderr);
});

test("hosted See proof fails closed on absent or incomplete evidence", () => {
  for (const mode of ["zero-discovery", "no-selected-id", "missing-id", "duplicate-id", "extra-selected-id", "display-id", "discovery-failed",
    "zero-execution", "missing-summary", "duplicate-summary", "wrong-count", "missing-pass", "extra-pass",
    "missing-argument", "duplicate-argument", "wrong-parameter-count", "execution-failed"]) {
    const result = runSeeProofFixture(mode);
    assert.notEqual(result.status, 0, mode);
    assert.equal(result.invocations.length, ["zero-discovery", "no-selected-id", "missing-id", "duplicate-id", "extra-selected-id", "display-id", "discovery-failed"].includes(mode) ? 1 : 2, mode);
  }
  const local = runSeeProofFixture("passed", false);
  assert.notEqual(local.status, 0);
  assert.match(local.stderr, /restricted to the secretless GitHub-hosted CI runner/);
});

test("See proof arguments agree with installed Swift help and parse without running discovery", {
  skip: process.platform !== "darwin",
}, () => {
  const directory = mkdtempSync(join(tmpdir(), "peekaboo-see-parser-"));
  const swift = (args) => spawnSync("swift", args, {
    cwd: directory, encoding: "utf8", timeout: 20_000,
  });
  try {
    const listHelp = swift(["test", "list", "--help-hidden"]);
    assert.equal(listHelp.status, 0, listHelp.stderr);
    // Parent test options can parse without being documented list options.
    assert.doesNotMatch(listHelp.stdout, /^\s+--(?:filter|parallel|no-parallel)\b/m);
    for (const option of ["--disable-xctest", "--enable-swift-testing", "-Xswiftc"]) {
      assert.ok(listHelp.stdout.includes(option), option);
    }
    const fixture = runSeeProofFixture("passed");
    assert.equal(fixture.status, 0, fixture.stderr);
    for (const args of fixture.invocations) {
      const help = swift([...args, "--help"]);
      assert.equal(help.status, 0, help.stderr);
      // --help alone masks bad flags. Force a parser error before command dispatch;
      // a preceding unknown option must win over this last, deliberate stop token.
      const stop = "--see-proof-parser-stop";
      const parsed = swift([...args, stop]);
      assert.equal(parsed.status, 64, parsed.stderr);
      assert.match(parsed.stderr, /^error: Unknown option '--see-proof-parser-stop'/m);
      const invalid = swift([...args, "--invalid-see-option", stop]);
      assert.equal(invalid.status, 64, invalid.stderr);
      assert.match(invalid.stderr, /^error: Unknown option '--invalid-see-option'/m);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
