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
const userActivationContractURL = new URL(
  "../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/BrowserMCPUserActivationPolicy.swift",
  import.meta.url,
);
const rootPackage = JSON.parse(readFileSync(rootPackageURL, "utf8"));
const dependencyPackage = JSON.parse(readFileSync(dependencyPackageURL, "utf8"));
const routingContract = readFileSync(routingContractURL, "utf8");
const semanticsContract = readFileSync(semanticsContractURL, "utf8");
const userActivationContract = readFileSync(userActivationContractURL, "utf8");
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
const expectedAlwaysForegroundNames = namesInContractSection(
  "user-activation-always-foreground",
  userActivationContract,
);
const expectedConditionalUserActivationNames = namesInContractSection(
  "user-activation-conditional",
  userActivationContract,
);
const expectedSourceProvenBackgroundNames = namesInContractSection(
  "user-activation-source-proven-background",
  userActivationContract,
);
const expectedElementReferencePaths = namesInContractSection("element-reference-path");
const expectedPageResponseNames = namesInContractSection("page-response");
const expectedSnapshotResponseNames = namesInContractSection("snapshot-response");

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
  experimentalStructuredContent: true,
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

const structuredFixtureTool = {
  name: "peekaboo_structured_fixture",
  description: "Exercises the real pinned ToolHandler structured-content gate",
  annotations: { category: "navigation" },
  schema: {},
  blockedByDialog: false,
  verifyFilesSchema: [],
  async handler(_request, response) {
    response.appendResponseLine("structured fixture");
  },
};
const fixtureContext = {
  consumeReconnectNotice() {
    return false;
  },
};
const structuredHandler = new ToolHandler(
  structuredFixtureTool,
  serverArgs,
  async () => fixtureContext,
  inertMutex,
);
const textOnlyHandler = new ToolHandler(
  structuredFixtureTool,
  { ...serverArgs, experimentalStructuredContent: false },
  async () => fixtureContext,
  inertMutex,
);
const structuredFixture = await structuredHandler.handle({});
const textOnlyFixture = await textOnlyHandler.handle({});
assert.equal(
  structuredFixture.structuredContent?.message,
  "structured fixture",
  "the pinned provider no longer emits opted-in structured content",
);
assert.equal(
  Object.hasOwn(textOnlyFixture, "structuredContent"),
  false,
  "structured-content proof must discriminate the provider's default text-only behavior",
);

function unwrapOptional(schema) {
  let current = schema;
  while (["ZodOptional", "ZodNullable", "ZodDefault"].includes(current?._def?.typeName)) {
    current = current._def.innerType;
  }
  return current;
}

function uidPaths(schema, prefix = "") {
  const current = unwrapOptional(schema);
  if (!current) return [];
  if (current._def?.typeName === "ZodString") {
    const description = `${schema?._def?.description ?? ""} ${current._def.description ?? ""}`;
    return /\buid\b/i.test(description) ? [prefix] : [];
  }
  if (current._def?.typeName === "ZodArray") {
    return uidPaths(current._def.type, `${prefix}[]`);
  }
  if (current._def?.typeName === "ZodObject") {
    return Object.entries(current.shape).flatMap(([key, child]) =>
      uidPaths(child, prefix ? `${prefix}.${key}` : key),
    );
  }
  return [];
}

const schemaElementReferencePaths = tools.flatMap((tool) =>
  uidPaths(handlers.get(tool.name).registeredInputSchema).map((path) => `${tool.name}.${path}`),
);
// execute_3p_developer_tool.params is intentionally JSON text in the Zod schema. McpPage resolves only
// top-level singleton {uid: String} parameter values, so keep that implementation-owned path explicit.
const mcpPageSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/McpPage.js", import.meta.url),
  "utf8",
);
const textSnapshotSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/TextSnapshot.js", import.meta.url),
  "utf8",
);
const mcpResponseSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/McpResponse.js", import.meta.url),
  "utf8",
);
const inputToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/tools/input.js", import.meta.url),
  "utf8",
);
const snapshotFormatterSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/formatters/SnapshotFormatter.js", import.meta.url),
  "utf8",
);
const screenshotToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/tools/screenshot.js", import.meta.url),
  "utf8",
);
const issueFormatterSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/formatters/IssueFormatter.js", import.meta.url),
  "utf8",
);
const waitForHelperSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/WaitForHelper.js", import.meta.url),
  "utf8",
);
const scriptToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/tools/script.js", import.meta.url),
  "utf8",
);
const pageToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/tools/pages.js", import.meta.url),
  "utf8",
);
const networkToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/tools/network.js", import.meta.url),
  "utf8",
);
const textSnapshotImplementationSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/TextSnapshot.js", import.meta.url),
  "utf8",
);
const puppeteerBundleSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/build/src/third_party/index.js", import.meta.url),
  "utf8",
);
assert.match(mcpPageSource, /Object\.values\(params\)/, "third-party parameter traversal changed");
assert.match(mcpPageSource, /Object\.keys\(value\)\.length === 1/, "third-party singleton UID rule changed");
assert.match(
  textSnapshotSource,
  /`\$\{node\.loaderId\}_\$\{backendNodeId\}`/,
  "snapshot UID document/node identity changed",
);
assert.match(
  textSnapshotSource,
  /uniqueBackendNodeIdToMcpId\.get\(uniqueBackendId\)/,
  "snapshot UID continuity lookup changed",
);
assert.match(
  textSnapshotSource,
  /uniqueBackendNodeIdToMcpId\.set\(uniqueBackendId, id\)/,
  "snapshot UID continuity binding changed",
);
assert.match(
  textSnapshotSource,
  /interestingOnly:\s*!verbose/,
  "verbose snapshots no longer select the full accessibility tree",
);
assert.match(
  textSnapshotSource,
  /`\$\{snapshotId\}_\$\{idCounter\+\+\}`/,
  "new snapshot UID allocation changed",
);
assert.match(
  mcpPageSource,
  /Element uid "\$\{uid\}" not found on page \$\{this\.id\}/,
  "provider element-error identifier shape changed",
);
assert.match(
  mcpPageSource,
  /Element with uid \$\{uid\} no longer exists on the page/,
  "provider detached-element identifier shape changed",
);
assert.match(
  snapshotFormatterSource,
  /const attributes = \[`uid=\$\{serializedAXNodeRoot\.id\}`\]/,
  "snapshot rows no longer start with their structural uid",
);
assert.match(
  snapshotFormatterSource,
  /attributes\.join\(' '\)/,
  "snapshot row construction changed",
);
assert.match(
  mcpResponseSource,
  /structuredContent\.message = this\.#textResponseLines\.join\('\\n'\)/,
  "provider structured result-message projection changed",
);
assert.match(
  mcpResponseSource,
  /this\.#page\.textSnapshot = await TextSnapshot\.create/,
  "snapshot responses no longer replace the page's live element identity map",
);
const messageProjectionIndex = mcpResponseSource.indexOf("structuredContent.message =");
const viewportStatusIndex = mcpResponseSource.indexOf("Emulating viewport:");
const snapshotMarkerIndex = mcpResponseSource.indexOf("## Latest page snapshot");
assert.ok(
  messageProjectionIndex >= 0 &&
    messageProjectionIndex < viewportStatusIndex &&
    viewportStatusIndex < snapshotMarkerIndex,
  "third-party result/status/snapshot ordering changed",
);
assert.match(
  mcpResponseSource,
  /Page \$\{selectedPageId\} is now selected/,
  "provider selected-page fallback note changed",
);
assert.match(
  inputToolSource,
  /File uploaded from \$\{filePath\}/,
  "provider upload-path response changed",
);
assert.match(
  screenshotToolSource,
  /Took a screenshot of node with uid "\$\{request\.params\.uid\}"/,
  "provider screenshot identifier echo changed",
);
assert.match(
  issueFormatterSource,
  /bodyParts\.push\('### Affected resources'\)/,
  "provider issue affected-resource section changed",
);
assert.match(
  puppeteerBundleSource,
  /send\('Runtime\.evaluate',[\s\S]{0,500}?userGesture:\s*true/,
  "Puppeteer Runtime.evaluate user-activation behavior changed",
);
assert.match(
  puppeteerBundleSource,
  /send\('Runtime\.callFunctionOn',[\s\S]{0,1000}?userGesture:\s*true/,
  "Puppeteer Runtime.callFunctionOn user-activation behavior changed",
);
assert.match(
  scriptToolSource,
  /evaluatable\.evaluateHandle\(`\(\$\{fnString\}\)`\)/,
  "evaluate_script no longer enters Puppeteer evaluation",
);
assert.match(
  waitForHelperSource,
  /this\.#page\.evaluateHandle\(timeout =>/,
  "provider wait-for-action stabilization no longer enters Puppeteer evaluation",
);
assert.match(
  pageToolSource,
  /response\.setIncludePages\(true\)/,
  "provider page actions no longer request page response formatting",
);
assert.match(
  mcpResponseSource,
  /const title = await fetchPageTitle\(mcpPage\.pptrPage\)/,
  "provider page responses no longer fetch page titles",
);
assert.match(
  mcpResponseSource,
  /async function fetchPageTitle\(page\)[\s\S]{0,160}?page\.title\(\)/,
  "provider page title formatting path changed",
);
assert.match(
  textSnapshotImplementationSource,
  /options\.devtoolsData \?\? \(await page\.getDevToolsData\(\)\)/,
  "provider snapshot DevTools-data fallback changed",
);
assert.match(
  networkToolSource,
  /if \(request\.params\.reqid\)[\s\S]{0,700}?await request\.page\.getDevToolsData\(\)/,
  "provider network request fallback changed",
);
assert.match(
  issueFormatterSource,
  /details\.push\(`uid=\$\{item\.uid\}`\)/,
  "provider issue resource identifier shape changed",
);
schemaElementReferencePaths.push("execute_3p_developer_tool.params{*}.uid");
schemaElementReferencePaths.sort();
const pageScopedTools = tools.filter((tool) => tool.pageScoped === true);
const pageTargetedNames = tools.filter((tool) => {
  const parsed = handlers.get(tool.name).registeredInputSchema.safeParse({});
  return !parsed.success && parsed.error.issues.some((issue) => issue.path[0] === "pageId");
}).map((tool) => tool.name).sort();
const pageScopedNames = pageScopedTools.map((tool) => tool.name).sort();
const explicitPageTargetNames = pageTargetedNames.filter((name) => !pageScopedNames.includes(name));
const globalNames = tools.map((tool) => tool.name).filter((name) => !pageTargetedNames.includes(name)).sort();
const registeredNames = tools.filter((tool) => handlers.get(tool.name).shouldRegister).map((tool) => tool.name).sort();
const auditedNames = [
  ...expectedPageScopedNames,
  ...expectedExplicitPageTargetNames,
  ...expectedGlobalNames,
  ...expectedBlockedSelectedPageNames,
].sort();

assert.equal(pageScopedTools.length, 32, "the pinned dependency page-scoped contract changed");
assert.equal(registeredNames.length, 29, "the pinned provider's default registered catalog changed");
assert.deepEqual(
  [
    ...expectedAlwaysForegroundNames,
    ...expectedConditionalUserActivationNames,
    ...expectedSourceProvenBackgroundNames,
  ].sort(),
  registeredNames,
  "user-activation policy must partition every default registered provider tool",
);
assert.equal(
  new Set([
    ...expectedAlwaysForegroundNames,
    ...expectedConditionalUserActivationNames,
    ...expectedSourceProvenBackgroundNames,
  ]).size,
  registeredNames.length,
  "user-activation policy categories must be disjoint",
);
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
assert.deepEqual(
  schemaElementReferencePaths,
  expectedElementReferencePaths,
  "Swift raw element-reference paths drifted from the pinned provider schemas",
);
assert.deepEqual(
  expectedPageResponseNames,
  ["close_page", "handle_dialog", "list_pages", "navigate_page", "new_page", "resize_page", "select_page"],
  "re-audit every provider tool that emits a page list",
);
assert.deepEqual(
  expectedSnapshotResponseNames,
  [
    "click", "click_at", "drag", "execute_3p_developer_tool", "fill", "fill_form", "hover", "press_key",
    "take_snapshot", "upload_file", "wait_for",
  ],
  "re-audit every provider tool that can emit a snapshot",
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
