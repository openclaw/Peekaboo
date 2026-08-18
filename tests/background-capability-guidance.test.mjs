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

test('background Agent type guidance requires an explicit non-dialog snapshot', () => {
  for (const path of ['docs/commands/agent.md', 'docs/MCP.md']) {
    const source = read(path);
    assert.match(source, /(?:typing|`type`).*requires an explicit fresh exact non-dialog snapshot/is);
    assert.match(source, /cannot include competing app(?:\/|, )PID(?:\/|, or )window selectors/is);
  }
  assert.match(read('docs/commands/type.md'), /Background-only Agent\/MCP.*explicit fresh exact non-dialog/s);
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
  const pressMetadata = read(
    'Apps/CLI/Sources/PeekabooCLI/Commands/Interaction/PressCommand+CommanderMetadata.swift'
  );

  assert.match(learn, /fresh exact non-dialog snapshot form/);
  assert.match(learn, /dialog input.*background AXValue/);
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
