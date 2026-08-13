import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));
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
