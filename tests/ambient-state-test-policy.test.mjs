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

test("hosted dialog metadata proof runs owner and output contracts without live automation", () => {
  const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
  const marker = "      - name: Run targeted dialog metadata and deadline contracts\n";
  assert.ok(workflow.includes(marker), "Missing hosted dialog metadata proof");
  const step = workflow.split(marker)[1].split("\n      - name:")[0];
  const suites = [
    "DialogMetadataReaderTests", "DialogMetadataContractTests", "DialogHierarchyReaderTests",
    "DialogHierarchyAttributeTests", "DialogOperationDeadlineTests", "ElementDetectionDetachedRunnerTests",
  ];
  assert.match(step, /working-directory: Core\/PeekabooAutomationKit/);
  assert.match(step, /PEEKABOO_INCLUDE_AUTOMATION_TESTS: "false"/);
  assert.match(step, /PEEKABOO_RUN_INPUT_AUTOMATION_TESTS: "false"/);
  assert.doesNotMatch(step, /(?:RUN_AUTOMATION_ACTIONS|RUN_AUTOMATION_TESTS): "true"/);
  assert.match(step, /swift test --no-parallel/);
  assert.equal(step.match(/--filter '([^']+)'/)?.[1], suites.join("|"));
  for (const suite of suites) {
    const source = readFileSync(
      `${repositoryRoot}/Core/PeekabooAutomationKit/Tests/PeekabooAutomationKitTests/${suite}.swift`, "utf8",
    );
    assert.match(source, new RegExp(`(?:class|struct) ${suite}\\b`), `${suite} must exist in this checkout`);
  }
  assert.match(step, /set -o pipefail/);
  assert.ok(step.includes(`grep -Fq "Test Suite 'DialogMetadataReaderTests' passed" "$test_log"`));
  assert.ok(step.includes(`grep -Fq 'Suite DialogMetadataContractTests passed after ' "$test_log"`));
  assert.ok(step.includes("grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after '"));
});

test("safe suite forces ambient-state tests off", () => {
  assert.match(
    packageJSON.scripts["test:safe"],
    /PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS=false swift test/,
  );
});

test("application running-state CI executes both production and Bridge suites with nonempty guards", () => {
  const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
  for (const [name, packagePath, suite] of [
    ["Run application running-state contracts", "Core/PeekabooAutomationKit", "ApplicationRunningStateTests"],
    ["Run Bridge application running-state contracts", "Core/PeekabooCore", "PeekabooBridgeApplicationRunningStateTests"],
  ]) {
    const step = workflow.split(`      - name: ${name}\n`)[1]?.split("\n      - ")[0];
    assert.ok(step, `Missing CI step: ${name}`);
    assert.ok(step.includes(`working-directory: ${packagePath}`));
    assert.ok(step.includes("set -euo pipefail"));
    assert.ok(step.includes(`swift test --no-parallel --filter ${suite} 2>&1 | tee "$test_log"`));
    assert.ok(step.includes(`grep -Fq 'Suite ${suite} passed after ' "$test_log"`));
    assert.ok(step.includes("grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after ' \"$test_log\""));
    assert.doesNotMatch(step, /(?:RUN_AUTOMATION_ACTIONS|PEEKABOO_INCLUDE_AUTOMATION_TESTS): "true"/);
  }
  assert.ok(workflow.includes("node --test tests/ambient-state-test-policy.test.mjs"));
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

for (const name of [
  "Remote-selected local mutation installs a caller barrier",
  "Remote coordinator rejects a host observation certificate that forbids preservation",
]) {
  test(`ambient mutation declaration requires the exact shared opt-in: ${name}`, () => {
    const lines = readFileSync(
      `${repositoryRoot}/Apps/CLI/Tests/CoreCLITests/InteractionMutationInvalidatorTests.swift`,
      "utf8",
    ).split("\n");
    const declaration = lines.indexOf(`    func \`${name}\`() async throws {`);
    assert.notEqual(declaration, -1, `Missing test declaration: ${name}`);
    assert.equal(
      lines[declaration - 1].trim(),
      '@Test(.enabled(if: ProcessInfo.processInfo.environment["PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS"] == "true"))',
      `The declaration must be immediately governed by the ambient-state gate: ${name}`,
    );
  });
}

test("hosted text route proof runs isolated SDK and background contracts with nonempty guards", () => {
  const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
  const body = workflow.split("      - name: Run SDK and background text route regressions\n")[1];
  assert.ok(body, "Missing SDK and background text route CI step");
  const step = body.split("\n      - name:")[0];
  assert.match(step, /working-directory: Core\/PeekabooAutomationKit/);
  assert.ok(step.includes("PEEKABOO_INCLUDE_AUTOMATION_TESTS: \"false\""));
  assert.ok(step.includes("PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS: \"false\""));
  assert.ok(step.includes("set -euo pipefail"));
  assert.ok(step.includes("filter='^PeekabooAutomationKitTests[.](TextInputRouteTests|TypeServiceForegroundPolicyTests|UIInputPolicyDefaultTests|BackgroundTextInputDeliveryTests|BackgroundTextRouteRefusalTests|BackgroundTextInputReceiverTests)/'"));
  assert.ok(step.includes("filter+='|^PeekabooAutomationKitTests[.]TypeServiceTargetResolutionTests/`(targeted printable characters preserve their exact Unicode payload|literal Unicode events discard inherited modifiers without changing text or destination)`\\('"));
  assert.ok(step.includes('--filter "$filter"'));
  assert.ok(step.includes("--disable-xctest --enable-swift-testing --no-parallel"));
  assert.ok(step.includes("Suite TextInputRouteTests passed after "));
  assert.ok(step.includes("Suite TypeServiceForegroundPolicyTests passed after "));
  assert.ok(step.includes("Suite UIInputPolicyDefaultTests passed after "));
  assert.ok(step.includes("Suite BackgroundTextInputDeliveryTests passed after "));
  assert.ok(step.includes("Suite BackgroundTextRouteRefusalTests passed after "));
  assert.ok(step.includes("Suite BackgroundTextInputReceiverTests passed after "));
  assert.ok(step.includes("Suite TypeServiceTargetResolutionTests passed after "));
  assert.ok(step.includes("grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after '"));
  assert.equal(step.match(/\bswift test\b/g)?.length, 1);
});

test("hosted CI runs exact hotkey receipt Core guards", () => {
  const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
  const body = workflow.split("      - name: Run exact hotkey receipt regressions\n")[1];
  assert.ok(body, "Missing exact hotkey receipt CI step");
  const step = body.split("\n      - name:")[0];
  assert.match(step, /working-directory: Core\/PeekabooCore/);
  assert.ok(step.includes("--filter '^PeekabooTests[.](HotkeySelectAllReceiptTests|MCPExactWindowKeyboardToolTests|TypeServiceAXFailureReceiptTests|TypingFinalReceiverBindingTests)/'"));
  assert.ok(step.includes("Suite HotkeySelectAllReceiptTests passed after "));
  assert.ok(step.includes("Suite MCPExactWindowKeyboardToolTests passed after "));
  assert.ok(step.includes("Suite TypeServiceAXFailureReceiptTests passed after "));
  assert.ok(step.includes("Suite TypingFinalReceiverBindingTests passed after "));
  assert.ok(step.includes("grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after '"));
  assert.equal(step.match(/\bswift test\b/g)?.length, 1);
  assert.doesNotMatch(step, /RUN_(?:AUTOMATION_TESTS|AUTOMATION_ACTIONS|LOCAL_TESTS): "true"/);
});

test("hosted foreground keyboard release CI selects only its isolated suites", () => {
  const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
  const marker = "      - name: Run foreground hotkey release contracts\n";
  assert.equal(workflow.split(marker).length, 2, "Expected exactly one foreground hotkey release step");
  const step = workflow.split(marker)[1].split("\n      - name:")[0];
  const suites = ["HotkeyServiceForegroundReleaseTests", "ForegroundKeyboardEventPairTests"];
  assert.match(step, /working-directory: Core\/PeekabooAutomationKit/);
  for (const name of [
    "PEEKABOO_INCLUDE_AUTOMATION_TESTS", "PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS",
    "PEEKABOO_RUN_INPUT_AUTOMATION_TESTS", "RUN_AUTOMATION_READ", "RUN_AUTOMATION_TESTS",
    "RUN_AUTOMATION_ACTIONS", "RUN_LOCAL_TESTS",
  ]) {
    assert.ok(step.includes(`${name}: "false"`), `${name} must be disabled`);
  }
  assert.match(step, /PEEKABOO_CONFIG_DISABLE_MIGRATION: "1"/);
  assert.match(step, /set -euo pipefail/);
  assert.ok(step.includes("swift test --disable-xctest --enable-swift-testing --no-parallel --jobs 4"));
  assert.equal(step.match(/\bswift test\b/g)?.length, 1);
  const filter = step.match(/--filter '([^']+)'/)?.[1];
  assert.equal(filter, `^PeekabooAutomationKitTests[.](${suites.join("|")})/`);
  const selection = new RegExp(filter);
  for (const suite of suites) {
    assert.ok(selection.test(`PeekabooAutomationKitTests.${suite}/normalRelease()`));
    assert.ok(!selection.test(`PeekabooAutomationKitTests.${suite}Extra/unsafe()`));
    assert.ok(!selection.test(`OtherTests.${suite}/normalRelease()`));
    assert.ok(step.includes(`grep -Fq 'Suite ${suite} passed after ' "$test_log"`));
    const source = readFileSync(
      `${repositoryRoot}/Core/PeekabooAutomationKit/Tests/PeekabooAutomationKitTests/${suite}.swift`, "utf8",
    );
    assert.doesNotMatch(source, /\.post\(|\.postToPid\(|Task\.sleep|NSWorkspace|NSApplication|executePeekabooCLI/);
  }
  for (const id of [
    "PeekabooAutomationKitTests.HotkeyServiceTargetingTests/targetedInput()",
    "PeekabooAutomationKitTests.TypeServiceTargetResolutionTests/foregroundInput()",
  ]) {
    assert.ok(!selection.test(id), id);
  }
  assert.ok(step.includes('2>&1 | tee "$test_log"'));
  assert.ok(step.includes("grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after ' \"$test_log\""));
  assert.doesNotMatch(step, /continue-on-error|--skip-build/);
  const source = readFileSync(
    `${repositoryRoot}/Core/PeekabooAutomationKit/Tests/PeekabooAutomationKitTests/HotkeyServiceForegroundReleaseTests.swift`, "utf8",
  );
  assert.match(source, /foregroundEventPoster: \{ event in/);
  assert.match(source, /frontmostApplicationResolver: \{ nil \}/);
  assert.match(source, /coordinationRootURL: self\.coordinationRoot/);
  const pairTests = readFileSync(
    `${repositoryRoot}/Core/PeekabooAutomationKit/Tests/PeekabooAutomationKitTests/ForegroundKeyboardEventPairTests.swift`, "utf8",
  );
  assert.match(pairTests, /TypeServiceSpecialKeyMapping\.postKey\(/);
  assert.match(pairTests, /makeEvent: \{/);
  assert.match(pairTests, /eventPoster: \{/);
  assert.match(pairTests, /interEventDelay: \{/);
});

test("hosted focus raise accounting uses exact non-native suites with nonempty guards", () => {
  const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
  const body = workflow.split("      - name: Run focus raise accounting contracts\n")[1];
  assert.ok(body, "Missing focus raise accounting CI step");
  const step = body.split("\n      - name:")[0];
  assert.match(step, /working-directory: Core\/PeekabooAutomationKit/);
  for (const name of [
    "PEEKABOO_INCLUDE_AUTOMATION_TESTS", "PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS",
    "PEEKABOO_RUN_INPUT_AUTOMATION_TESTS", "RUN_AUTOMATION_ACTIONS",
  ]) {
    assert.ok(step.includes(`${name}: "false"`));
  }
  assert.ok(step.includes("--filter '^PeekabooAutomationKitTests[.](FocusDispatchAccountingTests|FocusRaiseDispatchAccountingTests)/'"));
  assert.ok(step.includes("--disable-xctest --enable-swift-testing --no-parallel"));
  for (const suite of ["FocusDispatchAccountingTests", "FocusRaiseDispatchAccountingTests"]) {
    assert.ok(step.includes(`Suite ${suite} passed after `));
  }
  assert.ok(step.includes("grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after '"));
  assert.equal(step.match(/\bswift test\b/g)?.length, 1);
  assert.doesNotMatch(step, /--skip-build|: "true"/);
});

test("hosted mocked Press CI enables only its exact injected-service suite", () => {
  const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
  const body = workflow.split("      - name: Run mocked Press receipt regressions\n")[1];
  assert.ok(body, "Missing mocked Press receipt CI step");
  const step = body.split("\n      - name:")[0];
  assert.match(step, /working-directory: Apps\/CLI/);
  assert.match(step, /PEEKABOO_INCLUDE_AUTOMATION_TESTS: "true"/);
  assert.match(step, /PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS: "false"/);
  assert.match(step, /RUN_AUTOMATION_READ: "true"/);
  for (const name of ["RUN_AUTOMATION_TESTS", "RUN_AUTOMATION_ACTIONS", "RUN_LOCAL_TESTS"]) {
    assert.ok(step.includes(`${name}: "false"`));
  }
  assert.ok(step.includes("--filter '^CLIAutomationTests[.]PressCommandTests/'"));
  assert.ok(step.includes("--disable-xctest --enable-swift-testing --no-parallel"));
  assert.ok(step.includes("Suite PressCommandTests passed after "));
  assert.ok(step.includes("grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after '"));
  assert.equal(step.match(/\bswift test\b/g)?.length, 1);
  assert.doesNotMatch(step, /-DPEEKABOO_SKIP_AUTOMATION/);

  const source = readFileSync(`${repositoryRoot}/Apps/CLI/Tests/CLIAutomationTests/PressCommandTests.swift`, "utf8");
  assert.match(source, /automation: StubAutomationService = StubAutomationService\(\)/);
  assert.match(source, /windows: any WindowManagementServiceProtocol = StubWindowService/);
  assert.doesNotMatch(source, /executePeekabooCLI|NSWorkspace|NSApplication|BackgroundInputDriver/);
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

test("desktop lane lock CI executes the safe named suite and rejects empty proof", () => {
  const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
  const marker = "      - name: Run desktop operation lane lock contracts\n";
  assert.equal(workflow.split(marker).length, 2, "Expected exactly one desktop lane proof step");
  const step = workflow.split(marker)[1].split("\n      - name: ")[0];
  assert.match(step, /working-directory: Core\/PeekabooAutomationKit/);
  assert.match(step, /set -euo pipefail/);
  assert.ok(step.includes("swift test --no-parallel --filter 'DesktopOperationLaneCoordinatorTests'"));
  assert.ok(step.includes('2>&1 | tee "$test_log"'));
  assert.ok(step.includes("grep -Fq 'Suite DesktopOperationLaneCoordinatorTests passed after '"));
  assert.ok(step.includes("grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after '"));
  assert.doesNotMatch(step, /--skip-build/);
  assert.doesNotMatch(step, /(?:RUN_AUTOMATION_ACTIONS|RUN_AUTOMATION_TESTS|RUN_LOCAL_TESTS|PEEKABOO_INCLUDE_AUTOMATION_TESTS|PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS)\s*(?::|=)\s*["']?(?:true|1)\b/i);
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

const pasteSafetyProofs = [
  {
    name: "Run clipboard paste admission gate contracts",
    next: "Run mutation inventory, selector, and host window contracts",
    directory: "Core/PeekabooAutomationKit",
    suite: "ClipboardPasteTransactionGateTests",
    automation: "false",
    filter: "^PeekabooAutomationKitTests\\.ClipboardPasteTransactionGateTests/",
    selected: ["PeekabooAutomationKitTests.ClipboardPasteTransactionGateTests/`Late file-lock admission refuses and releases both gates`(lateness:)"],
    rejected: ["PeekabooAutomationKitTests.ClipboardPasteTransactionGateTestsExtra/unsafe()"],
    declarations: [],
    countGuard: "Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after ",
  },
  {
    name: "Run MCP paste admission timeout regressions",
    next: "Run Bridge negotiation and cancellation contracts",
    directory: "Core/PeekabooCore",
    suite: "PasteToolTransactionGateTests",
    automation: "false",
    filter: "^PeekabooTests\\.PasteToolTransactionGateTests/`(paste admission timeout preserves observations and releases the MCP reservation|admitted paste retains prior focus when its input lane times out)`\\(explicitPayload:\\)(/|$)",
    selected: [
      "PeekabooTests.PasteToolTransactionGateTests/`paste admission timeout preserves observations and releases the MCP reservation`(explicitPayload:)",
      "PeekabooTests.PasteToolTransactionGateTests/`admitted paste retains prior focus when its input lane times out`(explicitPayload:)",
    ],
    rejected: [
      "PeekabooTests.PasteToolTransactionGateTests/`MCP paste re-resolves its process after shared-lock contention`()",
      "PeekabooTests.PasteToolTransactionGateTests/`Current clipboard foreground paste can report successful dispatch`()",
    ],
    source: "Core/PeekabooCore/Tests/PeekabooTests/MCP/PasteToolTransactionGateTests.swift",
    declarations: [
      "paste admission timeout preserves observations and releases the MCP reservation",
      "admitted paste retains prior focus when its input lane times out",
    ],
    countGuard: "Test run with 2 tests( in 1 suite)? passed after ",
  },
  {
    name: "Run CLI paste admission timeout regression (skip automation)",
    next: "Run paste observation invalidation contracts (skip automation)",
    directory: "Apps/CLI",
    suite: "PasteCommandTests",
    automation: "true",
    filter: "^CLIAutomationTests\\.PasteCommandTests/`Admission timeout preserves observations and a later clipboard paste recovers`\\(binaryPayload:\\)(/|$)",
    selected: ["CLIAutomationTests.PasteCommandTests/`Admission timeout preserves observations and a later clipboard paste recovers`(binaryPayload:)"],
    rejected: [
      "CLIAutomationTests.PasteCommandTests/`Current clipboard paste waits for an active transaction`()",
      "CLIAutomationTests.PasteCommandTests/`Clipboard-backed paste re-resolves its process after lock contention`()",
    ],
    source: "Apps/CLI/Tests/CLIAutomationTests/PasteCommandTransactionGateTests.swift",
    declarations: ["Admission timeout preserves observations and a later clipboard paste recovers"],
    countGuard: "Test run with 1 test( in 1 suite)? passed after ",
  },
  {
    name: "Run paste observation invalidation contracts (skip automation)",
    next: "Run taskless agent resume regression (skip automation)",
    directory: "Apps/CLI",
    suite: "PasteObservationInvalidationTests",
    automation: "true",
    filter: "^CLIAutomationTests\\.PasteObservationInvalidationTests/",
    selected: [
      "CLIAutomationTests.PasteObservationInvalidationTests/`Admitted paste refusal preserves implicit latest only without earlier effects`(prefix:)",
      "CLIAutomationTests.PasteObservationInvalidationTests/`Background text predispatch refusal preserves observations without clipboard admission`()",
    ],
    rejected: [
      "CLIAutomationTests.PasteCommandTests/`Current clipboard paste waits for an active transaction`()",
      "CLIAutomationTests.PasteObservationInvalidationTestsExtra/`Unexpected declaration`()",
    ],
    countGuard: "Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after ",
  },
];

for (const proof of pasteSafetyProofs) {
  test(`paste safety CI selects only safe proof with complete pass evidence: ${proof.suite}`, () => {
    const workflow = readFileSync(`${repositoryRoot}/.github/workflows/macos-ci.yml`, "utf8");
    const marker = `      - name: ${proof.name}\n`;
    const sections = workflow.split(marker);
    assert.equal(sections.length, 2, `Expected exactly one step: ${proof.name}`);
    const nextStep = sections[1].match(/\n      - (?:name: ([^\n]+)|uses: [^\n]+)/);
    assert.ok(nextStep, `Missing next step after ${proof.name}`);
    assert.equal(nextStep[1], proof.next, "Keep the safe proof before the named existing step");
    const step = sections[1].slice(0, nextStep.index);
    assert.ok(step.includes(`working-directory: ${proof.directory}\n`));
    assert.ok(step.includes(`PEEKABOO_INCLUDE_AUTOMATION_TESTS: "${proof.automation}"`));
    assert.match(step, /PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS: "false"/);
    assert.doesNotMatch(step, /\b(?:RUN_AUTOMATION_ACTIONS|RUN_AUTOMATION_TESTS|RUN_LOCAL_TESTS)\s*[:=]/);
    assert.match(step, /set -euo pipefail/);
    assert.equal((step.match(/swift test /g) ?? []).length, 1);
    assert.match(step, /swift test --disable-xctest --enable-swift-testing --no-parallel/);
    assert.doesNotMatch(step, /--skip-build/);
    assert.ok(step.includes('2>&1 | tee "$test_log"'), "Retain the complete test log");
    const filters = [...step.matchAll(/--filter '([^']+)'/g)];
    assert.equal(filters.length, 1);
    assert.equal(filters[0][1], proof.filter);
    const selection = new RegExp(filters[0][1]);
    for (const id of proof.selected) assert.ok(selection.test(id), id);
    for (const id of proof.rejected) assert.ok(!selection.test(id), id);
    if (proof.source) {
      const source = readFileSync(`${repositoryRoot}/${proof.source}`, "utf8");
      for (const declaration of proof.declarations) {
        assert.ok(source.includes("func `" + declaration + "`"), declaration);
        assert.ok(step.includes(`grep -Eq 'Test "${declaration}"( with 2 test cases)? passed after ' "$test_log"`));
      }
      for (const id of proof.selected) {
        assert.ok(selection.test(`${id}/Fixture.swift:1:1`), "Swift Testing may append a source location");
        assert.ok(!selection.test(id.replaceAll("`", "")), "Display names are not declaration IDs");
        assert.ok(!selection.test(`${id}Extra`), "Do not admit extra declarations");
      }
    }
    assert.ok(step.includes(`grep -Fq 'Suite ${proof.suite} passed after ' "$test_log"`));
    assert.ok(step.includes(`grep -Eq '${proof.countGuard}' "$test_log"`));
    if (proof.directory === "Apps/CLI") {
      assert.match(step, /-Xswiftc -DPEEKABOO_SKIP_AUTOMATION/);
      assert.match(step, /PEEKABOO_CONFIG_DISABLE_MIGRATION: "1"/);
    }
  });
}
