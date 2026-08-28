import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = (path) => readFileSync(`${root}/${path}`, 'utf8');

test('cold-launch Agent examples carry explicit foreground authority', () => {
  for (const path of ['README.md', 'docs/index.md', 'docs/quickstart.md']) {
    const source = read(path);
    assert.match(
      source,
      /peekaboo agent "[^"]*open Safari[^"]*" --allow-foreground/i,
      `${path} must not advertise a cold Safari launch under the default background-only ceiling`
    );
  }
});

test('press guidance preserves the snapshot-pinned background route', () => {
  const readme = read('README.md');
  const agent = read('docs/commands/agent.md');
  const mcp = read('docs/MCP.md');
  const press = read('docs/commands/press.md');

  assert.doesNotMatch(readme, /Raw `press` chords always require explicit `--foreground`/);
  assert.match(readme, /fresh exact non-dialog snapshot/);
  assert.match(agent, /raw `press` requires a fresh exact non-dialog snapshot receipt/);
  assert.match(mcp, /Background-only raw `press` likewise requires an explicit fresh exact non-dialog snapshot/);
  assert.match(press, /Background-only Agent\/MCP.*explicit fresh exact non-dialog snapshot/s);
});

const isTargetedRawPress = (line) => /^peekaboo press\b.*--(?:app|pid)\b/.test(line);
const hasSafeRawPressRoute = (line) =>
  /--(?:foreground|snapshot|window-(?:id|title|index))\b/.test(line);

test('primary app automation examples stay exact-window and background-only', () => {
  for (const path of ['README.md', 'docs/quickstart.md']) {
    const source = read(path);
    assert.match(source, /^peekaboo window list --app Safari --json$/m);
    assert.match(source, /^peekaboo click .*--app Safari --window-id 12345$/m);
    assert.match(source, /^peekaboo type .*--app Safari --window-id 12345$/m);
    assert.match(source, /^peekaboo press Return --app Safari --window-id 12345$/m);
    assert.doesNotMatch(source, /^peekaboo press Return --app Safari --foreground$/m);
  }

  assert.match(read('README.md'), /Raw CLI `press` chords.*exact window selector/s);
  assert.match(read('README.md'), /snapshot.*required by background-only Agent\/MCP policy/s);

  const automation = read('docs/automation.md');
  assert.match(automation, /^peekaboo click .*--app Safari --window-id 12345$/m);
  assert.match(automation, /^peekaboo type .*--app Safari --window-id 12345$/m);
});

test('bundled skill never advertises app/PID-only background press', () => {
  const skill = read('skills/peekaboo/SKILL.md');
  const targetedPressExamples = skill
    .split('\n')
    .filter(isTargetedRawPress);

  assert.ok(targetedPressExamples.length > 0);
  for (const example of targetedPressExamples) {
    assert.equal(
      hasSafeRawPressRoute(example),
      true,
      `app/PID-only background press is not a valid route: ${example}`
    );
  }

  assert.equal(isTargetedRawPress('peekaboo press return --pid 1234'), true);
  assert.equal(hasSafeRawPressRoute('peekaboo press return --pid 1234'), false);
  assert.equal(hasSafeRawPressRoute('peekaboo press return --pid 1234 --window-id 42'), true);
});

test('bundled skill keeps routine management examples read-only', () => {
  const skill = read('skills/peekaboo/SKILL.md');

  assert.doesNotMatch(skill, /^peekaboo clipboard (?:set|clear|restore)\b/m);
  assert.doesNotMatch(skill, /^peekaboo permissions request\b/m);
  assert.doesNotMatch(skill, /^peekaboo app focus\b/m);
  assert.match(skill, /^peekaboo clipboard get --json$/m);
  assert.match(skill, /^peekaboo permissions status --all-sources --json$/m);
  assert.match(skill, /^peekaboo app list --include-hidden --include-background --json$/m);
});

test('background Agent type guidance requires an explicit non-dialog snapshot', () => {
  for (const path of ['docs/commands/agent.md', 'docs/MCP.md']) {
    const source = read(path);
    assert.match(source, /(?:typing|`type`).*requires an explicit fresh exact non-dialog snapshot/is);
    assert.match(source, /cannot include competing app(?:\/|, )PID(?:\/|, or )window selectors/is);
  }
  assert.match(read('docs/commands/type.md'), /Background-only Agent\/MCP.*explicit fresh exact non-dialog/s);
});

test('browser guidance separates standalone root authority from scoped sessions', () => {
  const browser = read('docs/commands/browser.md');
  const browserMcp = read('docs/browser-mcp.md');
  const mcp = read('docs/commands/mcp.md');
  const agent = read('docs/commands/agent.md');
  const changelog = read('CHANGELOG.md');
  const cliChangelog = read('Apps/CLI/CHANGELOG.md');
  const changelogContract =
    /explicit-foreground standalone CLI root auto-connect.*filtered MCP and Agent catalogs.*prevents shared-root fallback and unsafe reuse/s;

  assert.match(browser, /Default mode therefore exposes only source-audited routes.*refuse before provider\s+I\/O unless the caller passes `--foreground`/s);
  assert.match(browser, /source-audited calls report `browser_protocol` \/ `background` delivery/s);
  assert.match(browser, /accepted calls report `browser_protocol` \/ `foreground` delivery/s);
  assert.match(browser, /All default calls require an existing exact browser connection receipt and never ambiently auto-connect/s);
  assert.match(browser, /With explicit\s+`--foreground`.*only standalone CLI page actions may\s+auto-connect/s);
  assert.match(browser, /Persistent MCP, Agent, and\s+Bridge-scoped page actions never ambiently auto-connect/s);
  assert.match(browser, /newer snapshot or navigation expires the affected page's element references/s);
  assert.match(browser, /Closing a page\s+expires that page's namespace/s);
  assert.match(browserMcp, /status, execution, disconnect, and terminal end all carry the opaque session ID/s);
  assert.match(browserMcp, /Status returns the provider\s+epoch, and execution re-presents that epoch with the exact connection receipt/s);
  assert.match(browserMcp, /Persistent MCP and Agent sessions, including authenticated Bridge-scoped sessions/s);
  assert.match(browserMcp, /setup for that exact server-owned child/s);
  assert.doesNotMatch(browserMcp, /setup for that exact process-local child/s);
  assert.match(mcp, /Each server whose\s+catalog includes `browser`, or which consumes an explicit browser handoff/s);
  assert.doesNotMatch(mcp, /Each process-local\s+server owns a fresh browser child/s);
  assert.match(mcp, /Scoped MCP page actions never ambiently auto-connect, even\s+with foreground authority/s);
  assert.match(mcp, /`--allow-foreground` exposes the explicit `browser` `connect` action.*routes that can enter Puppeteer evaluation/s);
  assert.match(mcp, /default servers hide and pre-dispatch refuse page discovery.*arbitrary script evaluation/s);
  assert.match(mcp, /Foreground-authorized calls.*truthfully report foreground browser-protocol delivery/s);
  assert.match(mcp, /A background-only\s+Bridge-backed opaque browser session can start connected only through/s);
  assert.doesNotMatch(mcp, /Missing, stale, copied,/s);
  assert.match(mcp, /Filtering out `browser` therefore creates no browser\s+child/s);
  assert.match(mcp, /explicit `--browser-handoff` is still\s+authenticated, consumed, and opened/s);
  assert.match(agent, /Bridge-routed Agent never borrows the host's shared browser root/s);
  assert.match(agent, /browser-filtered Agent run opens no browser\s+scope/s);
  assert.match(agent, /Each browser-enabled Agent session opens one distinct end-capable remote child/s);
  assert.doesNotMatch(agent, /Each Agent session opens one distinct end-capable remote child/s);
  assert.match(agent, /unconfirmed cleanup is retained as retryable debt and blocks\s+session reuse/s);
  assert.match(changelog, changelogContract);
  assert.match(cliChangelog, changelogContract);
  const rootBullet = changelog
    .split('\n')
    .find((line) => line.includes('explicit-foreground standalone CLI root auto-connect'));
  const cliBullet = cliChangelog
    .split('\n')
    .find((line) => line.includes('explicit-foreground standalone CLI root auto-connect'));
  assert.equal(cliBullet, rootBullet, 'root and CLI changelogs must carry the same browser contract');
});

test('targeted dialog input is documented as background AXValue', () => {
  const dialog = read('docs/commands/dialog.md');
  assert.match(dialog, /Exact targeted.*input stay in the background/s);
  assert.match(dialog, /app\/PID\/window target default to background AXValue/);
  assert.match(dialog, /dialog input --text hunter2.*--app Safari$/m);
  assert.doesNotMatch(dialog, /dialog input --text hunter2.*--foreground/);
  assert.match(dialog, /`dialog file`.*require foreground\s+consent/s);
});

test('focus and Space examples never imply an implicit foreground switch', () => {
  const focus = read('docs/focus.md');
  assert.match(focus, /Keep targeted interaction in the background/);
  assert.match(focus, /Focus the target window only after explicit foreground consent/);
  assert.doesNotMatch(focus, /^peekaboo space switch --to 2$/m);
  assert.equal(
    focus.match(/^peekaboo space switch --to 2 --foreground$/gm)?.length,
    2
  );
  assert.match(focus, /peekaboo type "Hello" --foreground --bring-to-current-space/);
});

test('foreground-exposing action examples include consent', () => {
  const action = read('docs/commands/action.md');
  const exposingExamples = action
    .split('\n')
    .filter((line) => /^peekaboo action .*(AXPress|AXShowMenu)/.test(line));
  assert.ok(exposingExamples.length >= 2);
  for (const example of exposingExamples) {
    assert.match(example, /--foreground$/, `missing foreground consent: ${example}`);
  }
  assert.match(action, /state-only actions such as `AXIncrement` remain\s+background-capable/);
});

test('generated guidance sources retain CLI and policy distinctions', () => {
  const learn = read('Apps/CLI/Sources/PeekabooCLI/Commands/Core/LearnCommand.swift');
  const toolRegistry = read(
    'Core/PeekabooCore/Sources/PeekabooAgentRuntime/ToolRegistry/ToolRegistry.swift'
  );
  const typeTool = read(
    'Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Tools/TypeTool.swift'
  );
  const pressMetadata = read(
    'Apps/CLI/Sources/PeekabooCLI/Commands/Interaction/PressCommand+CommanderMetadata.swift'
  );

  assert.match(learn, /fresh exact non-dialog snapshot form/);
  assert.match(learn, /dialog input.*background AXValue/);
  assert.match(learn, /Foreground-only CLI pointer.*move and drag require explicit `--foreground` consent/);
  assert.doesNotMatch(learn, /\*\*UI Automation\*\*:.*\bdrag\b/);
  assert.doesNotMatch(learn, /\*\*System\*\*:\s*shell/);
  assert.doesNotMatch(learn, /type --app/);
  assert.doesNotMatch(toolRegistry, /peekaboo type .*--app/);
  assert.doesNotMatch(toolRegistry, /ToolOverride|toolOverrides/);
  assert.match(toolRegistry, /publicAgentTools\(\)/);
  assert.match(typeTool, /explicit fresh exact non-dialog snapshot receipt/);
  assert.match(pressMetadata, /Agent\/MCP background-only policy/);
  assert.match(pressMetadata, /never infers latest/);
});

test('security and local-test guidance retain exact background exceptions', () => {
  const security = read('docs/security.md');
  const localTests = read('Apps/CLI/Tests/LOCAL_TESTS.md');

  assert.match(security, /targeted input uses exact-target background AXValue/);
  assert.match(security, /typing requires an explicit\s+fresh exact non-dialog snapshot/);
  assert.doesNotMatch(localTests, /Public raw `press` refuses background delivery/);
  assert.match(localTests, /Agent\/MCP explicit fresh non-dialog snapshots remain available/);
});
