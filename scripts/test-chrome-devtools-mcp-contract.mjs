import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const rootPackageURL = new URL("../package.json", import.meta.url);
const dependencyPackageURL = new URL(
  "../node_modules/chrome-devtools-mcp/package.json",
  import.meta.url,
);
const routingContractURL = new URL(
  "../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/BrowserMCPPageRoutingContract.swift",
  import.meta.url,
);
const semanticsContractURL = new URL(
  "../Core/PeekabooFoundation/Sources/PeekabooFoundation/BrowserToolActionSemantics.swift",
  import.meta.url,
);
const rootPackage = JSON.parse(readFileSync(rootPackageURL, "utf8"));
const dependencyPackage = JSON.parse(readFileSync(dependencyPackageURL, "utf8"));
const routingContract = readFileSync(routingContractURL, "utf8");
const semanticsContract = readFileSync(semanticsContractURL, "utf8");
const declaredVersion = rootPackage.devDependencies?.["chrome-devtools-mcp"];

function namesInContractSection(name, source = routingContract) {
  const expression = new RegExp(
    `chrome-devtools-mcp-contract:${name}-begin([\\s\\S]*?)chrome-devtools-mcp-contract:${name}-end`,
  );
  const section = source.match(expression)?.[1];
  assert.ok(section, `missing ${name} section in Swift routing contract`);
  return [...section.matchAll(/"([^"]+)"/g)].map((match) => match[1]).sort();
}

const swiftVersion = routingContract.match(/dependencyVersion\s*=\s*"([^"]+)"/)?.[1];
const expectedPageScopedNames = namesInContractSection("page-scoped");
const expectedExplicitPageTargetNames = namesInContractSection("explicit-page-target");
const expectedGlobalNames = namesInContractSection("global");
const expectedBlockedSelectedPageNames = namesInContractSection("blocked-selected-page");
const expectedReadOnlyNames = namesInContractSection("semantic-read-only", semanticsContract);
const expectedMutatingNames = namesInContractSection("semantic-mutating", semanticsContract);
const expectedArgumentDependentNames = namesInContractSection("semantic-argument-dependent", semanticsContract);

assert.equal(declaredVersion, "1.6.0", "keep the audited browser routing contract pinned exactly");
assert.equal(dependencyPackage.version, declaredVersion, "installed Chrome DevTools MCP must match the pin");
assert.equal(swiftVersion, declaredVersion, "Swift browser routing contract must match the dependency pin");

const { ToolHandler } = await import(
  new URL("../node_modules/chrome-devtools-mcp/build/src/ToolHandler.js", import.meta.url)
);
const { createTools } = await import(
  new URL("../node_modules/chrome-devtools-mcp/build/src/tools/tools.js", import.meta.url)
);

const serverArgs = {
  experimentalPageIdRouting: true,
  slim: false,
  viaCli: false,
};
const inertMutex = {
  async acquire() {
    return { dispose() {} };
  },
};
const tools = createTools(serverArgs);
const handlers = new Map(
  tools.map((tool) => [tool.name, new ToolHandler(tool, serverArgs, async () => undefined, inertMutex)]),
);
const pageScopedTools = tools.filter((tool) => tool.pageScoped === true);
const pageTargetedNames = tools.filter((tool) => {
  const parsed = handlers.get(tool.name).registeredInputSchema.safeParse({});
  return !parsed.success && parsed.error.issues.some((issue) => issue.path[0] === "pageId");
}).map((tool) => tool.name).sort();
const pageScopedNames = pageScopedTools.map((tool) => tool.name).sort();
const explicitPageTargetNames = pageTargetedNames.filter((name) => !pageScopedNames.includes(name));
const globalNames = tools.map((tool) => tool.name).filter((name) => !pageTargetedNames.includes(name)).sort();
const auditedNames = [
  ...expectedPageScopedNames,
  ...expectedExplicitPageTargetNames,
  ...expectedGlobalNames,
  ...expectedBlockedSelectedPageNames,
].sort();

assert.equal(pageScopedTools.length, 32, "the pinned dependency page-scoped contract changed");
assert.deepEqual(pageScopedNames, expectedPageScopedNames, "Swift page-scoped raw-tool catalog drifted");
assert.deepEqual(
  explicitPageTargetNames,
  expectedExplicitPageTargetNames,
  "Swift explicit page-target raw-tool catalog drifted",
);
assert.deepEqual(
  globalNames,
  [...expectedGlobalNames, ...expectedBlockedSelectedPageNames].sort(),
  "Swift schema-global raw-tool catalog drifted",
);
assert.deepEqual(
  expectedBlockedSelectedPageNames,
  ["trigger_extension_action"],
  "re-audit selected-page blockers before changing this category",
);
assert.deepEqual(
  tools.map((tool) => tool.name).sort(),
  auditedNames,
  "audited routing categories must partition the complete upstream tool catalog",
);
assert.deepEqual(
  [...expectedReadOnlyNames, ...expectedMutatingNames, ...expectedArgumentDependentNames].sort(),
  auditedNames,
  "audited browser action semantics must partition the complete upstream tool catalog",
);
assert.equal(
  new Set([...expectedReadOnlyNames, ...expectedMutatingNames, ...expectedArgumentDependentNames]).size,
  auditedNames.length,
  "audited browser action semantic categories must be disjoint",
);
for (const tool of pageScopedTools) {
  const handler = handlers.get(tool.name);
  const parsed = handler.registeredInputSchema.safeParse({});

  assert.equal(parsed.success, false, `${tool.name} unexpectedly accepted an unscoped request`);
  assert.ok(
    parsed.error.issues.some((issue) => issue.path[0] === "pageId"),
    `${tool.name} does not require pageId with experimental routing enabled`,
  );
}

console.log(
  `test-chrome-devtools-mcp-contract: ok (${pageScopedTools.length} page-scoped, ` +
    `${pageTargetedNames.length} page-targeted, ${expectedGlobalNames.length} global, ` +
    `${expectedBlockedSelectedPageNames.length} blocked-selected-page tools, v${declaredVersion})`,
);
