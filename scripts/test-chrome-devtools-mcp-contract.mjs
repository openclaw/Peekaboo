import assert from "node:assert/strict";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";

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
const expectedUnsupportedResponseNames = namesInContractSection("unsupported-response");
const expectedUnavailableNames = namesInContractSection("unavailable");
const expectedOpenedPageResponseNames = namesInContractSection("opened-page-response");
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

assert.equal(declaredVersion, "1.13.0", "keep the audited browser routing contract pinned exactly");
assert.equal(dependencyPackage.version, declaredVersion, "installed Chrome DevTools MCP must match the pin");
assert.equal(swiftVersion, declaredVersion, "Swift browser routing contract must match the dependency pin");

// Exercise the exact embedded runtime loader, stopping before the stdio server entrypoint.
const bootstrapSwift = readFileSync(new URL(
  "../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/BrowserMCPProviderBootstrap.swift", import.meta.url,
), "utf8");
const bootstrap = bootstrapSwift.match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1]
  .replace(/^    /gm, "");
// The owner verifies Chrome on the persistent provider socket, before page work.
const connectionBootstrap = bootstrap.split("process.argv =")[0];
assert.ok(connectionBootstrap.includes("peekaboo_browser_connect"),
  "native channel connect must verify the provider socket instead of opening a separate approval probe");
const originalPath = process.env.PATH;
process.env.PATH = fileURLToPath(new URL("../node_modules/.bin", import.meta.url)) + delimiter + originalPath;
await import("data:text/javascript," + encodeURIComponent(bootstrap.split("process.argv =")[0]));
process.env.PATH = originalPath;
const handlerURL = new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/ToolHandler.js", import.meta.url);
const { ToolHandler } = await import(handlerURL);
const { ToolHandler: UnpatchedToolHandler } = await import(new URL(handlerURL.href + "?unpatched-regression"));
const { createTools } = await import(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/tools/tools.js", import.meta.url)
);

const { mcpOptions } = await import(new URL(
  "../node_modules/chrome-devtools-mcp/out/Default/gen/src/config/mcp-options.js", import.meta.url,
));
const serverArgs = {
  ...Object.fromEntries(Object.entries(mcpOptions).map(([key, option]) => [key, option.default])),
  usageStatistics: false,
  pageIdRouting: true,
  experimentalStructuredContent: true,
  slim: false,
  viaCli: false,
};
const inertQueue = {
  async scheduleTask() {
    return { [Symbol.dispose]() {} };
  },
};
const tools = createTools(serverArgs);
const handlers = new Map(
  tools.map((tool) => [tool.name, new ToolHandler(tool, { resolved: serverArgs }, async () => undefined, () => {})]),
);

// Exercise the actual screenshot handler: v1.13.0 added a geometry probe to full-page shots.
assert.equal(serverArgs.screenshotMaxWidth, undefined);
assert.equal(serverArgs.screenshotMaxHeight, undefined);
const screenshotTool = tools.find((tool) => tool.name === "take_screenshot");
let geometryReads = 0;
let viewportCaptures = 0;
const screenshotPage = {
  pptrPage: {
    async evaluate() { geometryReads++; throw new Error("geometry grants activation"); },
    async screenshot() { viewportCaptures++; return new Uint8Array([1, 2, 3]); },
  },
};
const screenshotResponse = { appendResponseLine() {}, attachImage() {} };
await screenshotTool.handler({ page: screenshotPage, params: { format: "png" } }, screenshotResponse, {});
assert.equal(geometryReads, 0, "the default viewport screenshot must remain free of page evaluation");
assert.equal(viewportCaptures, 1);
await assert.rejects(screenshotTool.handler(
  { page: screenshotPage, params: { format: "png", fullPage: true } }, screenshotResponse, {},
), /geometry grants activation/);
assert.equal(geometryReads, 1, "full-page screenshots require foreground authority before provider I/O");

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
let disabledTelemetryMetadataReads = 0;
const fixtureContext = {
  browser: { process() { return {}; } },
  taskQueue: inertQueue,
  async ensureBrowser() { return this.browser; },
  async getDevToolsData() {
    disabledTelemetryMetadataReads++;
    throw new Error("Disabled telemetry must not inspect DevTools UI");
  },
  getSelectedMcpPageUrl() {
    disabledTelemetryMetadataReads++;
    throw new Error("Disabled telemetry must not inspect a selected page");
  },
  consumeReconnectNotice() {
    return false;
  },
};
const unpatchedFixture = await new UnpatchedToolHandler(
  structuredFixtureTool, { resolved: serverArgs }, async () => fixtureContext, () => {},
).handle({});
assert.equal(unpatchedFixture.isError, true, "the unfixed 1.13.0 handler must reproduce the telemetry probe");
assert.equal(disabledTelemetryMetadataReads, 1, "the negative control must reach DevTools metadata");
disabledTelemetryMetadataReads = 0;
const structuredHandler = new ToolHandler(
  structuredFixtureTool,
  { resolved: serverArgs },
  async () => fixtureContext,
  () => {},
);
const textOnlyHandler = new ToolHandler(
  structuredFixtureTool,
  { resolved: { ...serverArgs, experimentalStructuredContent: false } },
  async () => fixtureContext,
  () => {},
);
const structuredFixture = await structuredHandler.handle({});
const textOnlyFixture = await textOnlyHandler.handle({});
assert.equal(
  disabledTelemetryMetadataReads,
  0,
  "disabled telemetry must not add page/DevTools probes after an otherwise inert tool call",
);
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
const failedHandler = new ToolHandler(
  { ...structuredFixtureTool, async handler() { throw new Error("fixture tool failed"); } },
  { resolved: serverArgs }, async () => fixtureContext, () => {},
);
assert.equal((await failedHandler.handle({})).isError, true);
assert.equal(disabledTelemetryMetadataReads, 0, "failed tools must also skip disabled telemetry probes");

// The patch only gates telemetry: real tool-owned DevTools reads must retain their normal semantics.
const metadataHandler = new ToolHandler(
  { ...structuredFixtureTool, async handler(_request, _response, context) { await context.getDevToolsData(); } },
  { resolved: serverArgs }, async () => fixtureContext, () => {},
);
assert.equal((await metadataHandler.handle({})).isError, true);
assert.equal(disabledTelemetryMetadataReads, 1, "do not stub the shared DevTools helper");

const { ClearcutLogger } = await import(new URL(
  "../node_modules/chrome-devtools-mcp/out/Default/gen/src/telemetry/ClearcutLogger.js", import.meta.url,
));
const originalGetLogger = ClearcutLogger.get;
let loggedInvocation;
ClearcutLogger.get = () => ({ logToolInvocation(value) { loggedInvocation = value; } });
try {
  const enabledContext = {
    ...fixtureContext,
    async getDevToolsData() { return { fixture: "devtools" }; },
    getSelectedMcpPageUrl() { return "https://example.invalid/"; },
  };
  const result = await new ToolHandler(
    structuredFixtureTool, { resolved: { ...serverArgs, usageStatistics: true } }, async () => enabledContext, () => {},
  ).handle({});
  assert.equal(result.isError, undefined);
  assert.deepEqual(loggedInvocation.devToolsData, { fixture: "devtools" });
  assert.equal(loggedInvocation.pageUrl, "https://example.invalid/");
} finally {
  ClearcutLogger.get = originalGetLogger;
}

const localBin = fileURLToPath(new URL("../node_modules/.bin", import.meta.url));
const versionProbe = spawnSync(process.execPath, ["--input-type=module", "--eval", bootstrap, "--", "--version"], {
  encoding: "utf8", timeout: 30_000, env: { ...process.env, PATH: localBin + delimiter + originalPath },
});
assert.equal(versionProbe.status, 0, "the complete embedded launcher must start the pinned provider");
assert.equal(versionProbe.stdout.trim(), declaredVersion);

const tamperedRoot = mkdtempSync(join(tmpdir(), "peekaboo-provider-contract-"));
try {
  const fakeBin = join(tamperedRoot, "node_modules/.bin");
  const fakePackage = join(tamperedRoot, "node_modules/chrome-devtools-mcp");
  mkdirSync(fakeBin, { recursive: true });
  mkdirSync(join(fakePackage, "out/Default/gen/src"), { recursive: true });
  writeFileSync(join(fakePackage, "package.json"), JSON.stringify({
    name: "chrome-devtools-mcp", version: declaredVersion, type: "module",
  }));
  writeFileSync(join(fakePackage, "out/Default/gen/src/ToolHandler.js"), "throw new Error('unverified code ran');");
  const rejected = spawnSync(process.execPath, ["--input-type=module", "--eval", bootstrap], {
    encoding: "utf8", timeout: 10_000, env: { ...process.env, PATH: fakeBin + delimiter + originalPath },
  });
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /Error: Peekaboo: unaudited Chrome DevTools MCP ToolHandler/);
  assert.doesNotMatch(rejected.stderr, /Error: unverified code ran/);

  rmSync(fakePackage, { recursive: true });
  cpSync(realpathSync(fileURLToPath(new URL(".", dependencyPackageURL))), fakePackage, { recursive: true });
  for (const [module, diagnostic] of [
    ["ToolHandler.js", "ToolHandler"],
    ["BrowserManager.js", "browser transport"],
    ["third_party/index.js", "dependencies"],
  ]) {
    const path = join(fakePackage, "out/Default/gen/src", module);
    const original = readFileSync(path);
    writeFileSync(path, Buffer.concat([original, Buffer.from("\nthrow new Error('unverified code ran');\n")]));
    const result = spawnSync(process.execPath, ["--input-type=module", "--eval", connectionBootstrap], {
      encoding: "utf8", timeout: 10_000, env: { ...process.env, PATH: fakeBin + delimiter + originalPath },
    });
    assert.notEqual(result.status, 0, `tampered ${module} must fail before provider startup`);
    assert.ok(result.stderr.includes(`Error: Peekaboo: unaudited Chrome DevTools MCP ${diagnostic}`));
    assert.doesNotMatch(result.stderr, /Error: unverified code ran/);
    writeFileSync(path, original);
  }

  writeFileSync(join(fakePackage, "package.json"), JSON.stringify({ ...dependencyPackage, version: "1.13.1" }));
  const wrongVersion = spawnSync(process.execPath, ["--input-type=module", "--eval", connectionBootstrap], {
    encoding: "utf8", timeout: 10_000, env: { ...process.env, PATH: fakeBin + delimiter + originalPath },
  });
  assert.notEqual(wrongVersion.status, 0);
  assert.match(wrongVersion.stderr, /unexpected Chrome DevTools MCP package/);

  const pluginData = join(tamperedRoot, "plugin-data");
  mkdirSync(pluginData);
  writeFileSync(join(pluginData, "cd4a.config.json"), JSON.stringify({
    allowUnrestrictedPaths: true, categoryExtensions: true, pageIdRouting: false,
  }));
  const configProbe = spawnSync(process.execPath, ["--input-type=module", "--eval", connectionBootstrap + `
    const {ConfigParser} = await import(pathToFileURL(join(modules, 'config/ConfigParser.js')).href);
    const config = new ConfigParser('fixture', ['node', 'fixture', '--no-usage-statistics', '--page-id-routing']).parseConfig();
    const {default: assert} = await import('node:assert/strict');
    assert.equal(config.configPath, undefined);
    assert.notEqual(config.resolved.allowUnrestrictedPaths, true);
    assert.notEqual(config.resolved.categoryExtensions, true);
    assert.equal(config.resolved.pageIdRouting, true);
  `], {
    encoding: "utf8", timeout: 10_000,
    env: { ...process.env, PATH: localBin + delimiter + originalPath, PLUGIN_DATA: pluginData,
      CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY: "" },
  });
  assert.equal(configProbe.status, 0, `ambient provider config must not gain authority: ${configProbe.stderr}`);
} finally {
  rmSync(tamperedRoot, { recursive: true, force: true });
}

function unwrapOptional(schema) {
  let current = schema;
  while (["optional", "nullable", "default"].includes(current?._def?.type)) {
    current = current._def.innerType;
  }
  return current;
}

function uidPaths(schema, prefix = "") {
  const current = unwrapOptional(schema);
  if (!current) return [];
  if (current._def?.type === "string") {
    const description = `${schema?.description ?? ""} ${current.description ?? ""}`;
    return /\buids?\b/i.test(description) ? [prefix] : [];
  }
  if (current._def?.type === "array") {
    return uidPaths(current._def.element, `${prefix}[]`);
  }
  if (current._def?.type === "object") {
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
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/McpPage.js", import.meta.url),
  "utf8",
);
const textSnapshotSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/TextSnapshot.js", import.meta.url),
  "utf8",
);
const mcpResponseSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/McpResponse.js", import.meta.url),
  "utf8",
);
const inputToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/tools/input.js", import.meta.url),
  "utf8",
);
const snapshotFormatterSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/formatters/SnapshotFormatter.js", import.meta.url),
  "utf8",
);
const screenshotToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/tools/screenshot.js", import.meta.url),
  "utf8",
);
const issueFormatterSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/formatters/IssueFormatter.js", import.meta.url),
  "utf8",
);
const waitForHelperSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/utils/WaitForHelper.js", import.meta.url),
  "utf8",
);
const scriptToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/tools/script.js", import.meta.url),
  "utf8",
);
const pageToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/tools/pages.js", import.meta.url),
  "utf8",
);
const networkToolSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/tools/network.js", import.meta.url),
  "utf8",
);
const textSnapshotImplementationSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/TextSnapshot.js", import.meta.url),
  "utf8",
);
const puppeteerBundleSource = readFileSync(
  new URL("../node_modules/chrome-devtools-mcp/out/Default/gen/src/third_party/index.js", import.meta.url),
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
assert.match(textSnapshotSource, /if \(backendNodeId !== undefined\)/,
  "non-targetable accessibility nodes must not acquire UIDs");
const { TextSnapshot } = await import(new URL(
  "../node_modules/chrome-devtools-mcp/out/Default/gen/src/TextSnapshot.js", import.meta.url,
));
let syntheticNode = { role: "button", backendNodeId: 17, loaderId: "loader-a" };
const snapshotPage = {
  uniqueBackendNodeIdToMcpId: new Map(),
  extraHandles: [],
  pptrPage: { accessibility: { async snapshot() { return structuredClone(syntheticNode); } } },
};
const firstUID = (await TextSnapshot.create(snapshotPage, { devtoolsData: {} })).root.id;
assert.equal((await TextSnapshot.create(snapshotPage, { devtoolsData: {} })).root.id, firstUID,
  "one page must preserve the UID of the same document/node pair");
syntheticNode = { ...syntheticNode, loaderId: "loader-b" };
assert.notEqual((await TextSnapshot.create(snapshotPage, { devtoolsData: {} })).root.id, firstUID,
  "a new document must not inherit the old UID even if Chrome reuses the backend node ID");
const otherPage = { ...snapshotPage, uniqueBackendNodeIdToMcpId: new Map() };
assert.notEqual((await TextSnapshot.create(otherPage, { devtoolsData: {} })).root.id, firstUID,
  "UID continuity must not cross page namespaces");
syntheticNode = { role: "StaticText", children: [{ role: "InlineTextBox" }] };
const untargetable = await TextSnapshot.create(snapshotPage, { devtoolsData: {} });
assert.equal(untargetable.root.id, "");
assert.equal(untargetable.idToNode.size, 0);
assert.deepEqual(untargetable.root.children, []);
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
  /attributes\.push\(`uid=\$\{serializedAXNodeRoot\.id\}`\)/,
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
  /File uploaded from \$\{filePaths\.join\(', '\)\}/,
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
  /send\("Runtime\.evaluate",[\s\S]{0,500}?userGesture:\s*true/,
  "Puppeteer Runtime.evaluate user-activation behavior changed",
);
assert.match(
  puppeteerBundleSource,
  /send\("Runtime\.callFunctionOn",[\s\S]{0,1000}?userGesture:\s*true/,
  "Puppeteer Runtime.callFunctionOn user-activation behavior changed",
);
assert.match(
  scriptToolSource,
  /evaluatable\.evaluateHandle\(`\(\\n\$\{functionSource\}\\n\)`\)/,
  "evaluate_script no longer enters Puppeteer evaluation",
);
assert.match(
  scriptToolSource,
  /await evaluatable\.evaluate\(/,
  "re-audit the synthetic DOM click evaluation route",
);
assert.doesNotMatch(
  scriptToolSource,
  /\bInput\.|\.mouse\./,
  "evaluate_script unexpectedly reaches trusted pointer input",
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
assert.match(mcpResponseSource, /mcpPage\.getTitle\(targetInfo\)/,
  "provider page titles must use target metadata");
assert.doesNotMatch(mcpResponseSource, /\.title\(/,
  "provider page formatting must not regain Puppeteer evaluation");
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
const pageScopedNames = pageScopedTools.filter((tool) => !expectedBlockedSelectedPageNames.includes(tool.name))
  .map((tool) => tool.name).sort();
const explicitPageTargetNames = pageTargetedNames.filter((name) => !pageScopedNames.includes(name));
const globalNames = tools.map((tool) => tool.name).filter((name) => !pageTargetedNames.includes(name)).sort();
const registeredNames = tools.filter((tool) => !handlers.get(tool.name).disabled).map((tool) => tool.name).sort();
const auditedNames = [
  ...expectedPageScopedNames,
  ...expectedExplicitPageTargetNames,
  ...expectedGlobalNames,
  ...expectedBlockedSelectedPageNames,
].sort();

assert.equal(pageScopedTools.length, 44, "the pinned dependency page-scoped contract changed");
assert.equal(registeredNames.length, 33, "the pinned provider's default registered catalog changed");
assert.deepEqual(
  [
    ...expectedAlwaysForegroundNames,
    ...expectedConditionalUserActivationNames,
    ...expectedSourceProvenBackgroundNames,
    ...expectedUnsupportedResponseNames,
    ...expectedUnavailableNames.filter((name) => registeredNames.includes(name)),
  ].sort(),
  registeredNames,
  "user-activation policy and response refusals must partition every default registered provider tool",
);
assert.equal(
  new Set([
    ...expectedAlwaysForegroundNames,
    ...expectedConditionalUserActivationNames,
    ...expectedSourceProvenBackgroundNames,
    ...expectedUnsupportedResponseNames,
    ...expectedUnavailableNames.filter((name) => registeredNames.includes(name)),
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
  ["evaluate", "navigate", "screenshot", "trigger_extension_action"],
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
  ["close_page", "handle_dialog", "launch_pwa", "list_pages", "navigate_page", "new_page", "resize_page", "select_page", "uninstall_pwa"],
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
assert.deepEqual(expectedOpenedPageResponseNames, [
  "click", "click_at", "drag", "evaluate_script", "fill", "fill_form", "hover", "press_key", "type_text",
], "re-audit tools that can emit partial opened-page lists");
assert.match(mcpResponseSource, /structuredContent\.openedPages = structuredPages/,
  "provider opened-page response contract changed");
assert.deepEqual(expectedUnavailableNames, [
  "analyze_heapsnapshot_contexts", "configure_webauthn", "evaluate", "get_devtools_comments", "mock_network",
  "navigate", "open_devtools", "remove_network_mock", "resolve_devtools_comment", "reveal_in_devtools",
  "screenshot", "set_logpoints",
], "new upstream tools must remain unavailable until separately audited for exposure");
for (const tool of pageScopedTools.filter((tool) => !expectedBlockedSelectedPageNames.includes(tool.name))) {
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
