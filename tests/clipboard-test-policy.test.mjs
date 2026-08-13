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

test("safe suite forces live clipboard tests off", () => {
  assert.match(
    packageJSON.scripts["test:safe"],
    /PEEKABOO_INCLUDE_CLIPBOARD_TESTS=false swift test/,
  );
});

test("live clipboard smoke test requires the exact explicit opt-in", () => {
  assert.match(
    runtimeTests,
    /environment\["PEEKABOO_INCLUDE_CLIPBOARD_TESTS"\] == "true"/,
  );
  assert.match(
    runtimeTests,
    /@Test\(\.enabled\(if: CLIRuntimeEnvironment\.runClipboardTests\)\)/,
  );
});
