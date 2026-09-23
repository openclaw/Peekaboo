import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { selectHomebrewReleaseAssets } from '../scripts/select-homebrew-release-assets.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const workflow = readFileSync(join(root, '.github/workflows/update-homebrew.yml'), 'utf8');
const tag = 'v4.5.0';
const arm = { name: 'peekaboo-macos-arm64.tar.gz', state: 'uploaded', digest: `sha256:${'a'.repeat(64)}` };
const intel = { name: 'peekaboo-macos-x86_64.tar.gz', state: 'uploaded', digest: `sha256:${'b'.repeat(64)}` };
const universal = { name: 'peekaboo-macos-universal.tar.gz', state: 'uploaded', digest: null };
const release = (assets) => ({ tag_name: tag, draft: false, assets });
const expectedAssets = {
  darwin_arm64: { name: arm.name, sha256: 'a'.repeat(64) },
  darwin_amd64: { name: intel.name, sha256: 'b'.repeat(64) },
};

test('selects exact thin CLI assets and digest fields, ignoring app and npm assets', () => {
  const result = selectHomebrewReleaseAssets(release([
    intel, universal, { name: 'Peekaboo.zip' }, { name: 'steipete-peekaboo-4.5.0.tgz' }, arm,
  ]), tag);
  assert.deepEqual(JSON.parse(result.assets), expectedAssets);
  assert.equal(result.macos_artifact, undefined);
});

test('keeps universal-only releases usable without a historical API digest', () => {
  assert.deepEqual(selectHomebrewReleaseAssets(release([universal]), tag), { macos_artifact: universal.name });
});

for (const asset of [arm, intel]) {
  test(`rejects a partial pair containing ${asset.name}, even with universal available`, () => {
    assert.throws(() => selectHomebrewReleaseAssets(release([asset, universal]), tag), /Both thin/);
  });
}

for (const asset of [arm, intel, universal]) {
  test(`rejects duplicate ${asset.name}`, () => {
    assert.throws(() => selectHomebrewReleaseAssets(release([arm, intel, universal, asset]), tag), /Duplicate/);
  });
}

test('rejects absent, malformed, and non-SHA-256 thin digests', () => {
  for (const digest of [undefined, null, '', 'a'.repeat(64), `sha512:${'a'.repeat(64)}`, `sha256:${'A'.repeat(64)}`]) {
    assert.throws(() => selectHomebrewReleaseAssets(release([{ ...arm, digest }, intel]), tag), /SHA-256 digest/);
  }
});

test('requires uploaded assets and the requested published release', () => {
  assert.throws(() => selectHomebrewReleaseAssets(release([]), tag), /Missing uploaded/);
  assert.throws(() => selectHomebrewReleaseAssets(release([{ ...universal, state: 'starter' }]), tag), /Missing uploaded/);
  assert.throws(() => selectHomebrewReleaseAssets(release([{ ...arm, state: 'starter' }, intel]), tag), /uploaded asset/);
  for (const inventory of [null, {}, { ...release([arm, intel]), draft: true }, release([arm, intel])]) {
    assert.throws(() => selectHomebrewReleaseAssets(inventory, 'v0.0.0'), /published release inventory/);
  }
});

function stepScript(name) {
  const step = workflow.split(/^      - /m).find((value) => value.startsWith(`name: ${name}\n`));
  const body = step?.match(/^        run: \|\n((?: {10}[^\n]*\n|\n)+)/m)?.[1];
  assert.ok(body, `Missing workflow step: ${name}`);
  return body.replace(/^ {10}/gm, '');
}

function runHandoff(inventory, { apiExit = 0, watchExit = 0 } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'peekaboo-homebrew-test-'));
  try {
    const log = join(dir, 'calls.jsonl');
    const output = join(dir, 'output');
    writeFileSync(join(dir, 'gh'), `#!${process.execPath}
import { appendFileSync } from 'node:fs';
const args = process.argv.slice(2);
appendFileSync(process.env.CALL_LOG, JSON.stringify(args) + '\\n');
if (args[0] === 'api') {
  if (process.env.API_EXIT !== '0') process.exit(Number(process.env.API_EXIT));
  process.stdout.write(process.env.RELEASE_JSON);
} else if (args[0] === 'run' && args[1] === 'list') {
  console.log('4321');
} else if (args[0] === 'run' && args[1] === 'watch') {
  process.exit(Number(process.env.WATCH_EXIT));
} else if (args[0] !== 'workflow' || args[1] !== 'run') {
  process.exit(99);
}
`, { mode: 0o755 });
    const env = {
      PATH: `${dir}:${dirname(process.execPath)}:/usr/bin:/bin`,
      CALL_LOG: log, RELEASE_JSON: JSON.stringify(inventory), API_EXIT: String(apiExit), WATCH_EXIT: String(watchExit),
      GITHUB_OUTPUT: output, GITHUB_REPOSITORY: 'openclaw/Peekaboo', RELEASE_TAG: tag,
      GITHUB_RUN_ID: '101', GITHUB_RUN_ATTEMPT: '2', GH_TOKEN: 'fixture-read-token',
    };
    const run = (name, extra = {}) => spawnSync('/bin/bash', ['--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', stepScript(name)], {
      cwd: root, env: { ...env, ...extra }, encoding: 'utf8',
    });
    const selection = run('Select release assets');
    let dispatch;
    if (selection.status === 0) {
      const inputs = Object.fromEntries(readFileSync(output, 'utf8').trim().split('\n').map((line) => {
        const equals = line.indexOf('=');
        return [line.slice(0, equals), line.slice(equals + 1)];
      }));
      dispatch = run('Dispatch tap formula update', {
        GH_TOKEN: 'fixture-write-token', ASSETS_JSON: inputs.assets ?? '', MACOS_ARTIFACT: inputs.macos_artifact ?? '',
      });
    }
    return {
      selection, dispatch,
      calls: readFileSync(log, 'utf8').trim().split('\n').map((line) => JSON.parse(line)),
      output: readFileSync(output, 'utf8'),
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

for (const [name, assets, input] of [
  ['thin', [arm, intel, universal], `assets=${JSON.stringify(expectedAssets)}`],
  ['legacy', [universal], `macos_artifact=${universal.name}`],
]) {
  test(`workflow dispatches the ${name} inventory and waits for its matching tap run`, () => {
    const result = runHandoff(release(assets));
    assert.equal(result.selection.status, 0, result.selection.stderr);
    assert.equal(result.dispatch.status, 0, result.dispatch.stderr);
    assert.deepEqual(result.calls[0], ['api', `repos/openclaw/Peekaboo/releases/tags/${tag}`]);
    assert.deepEqual(result.calls[1], [
      'workflow', 'run', 'update-formula.yml', '--repo', 'openclaw/homebrew-tap', '--ref', 'main',
      '-f', 'formula=peekaboo', '-f', `tag=${tag}`, '-f', 'repository=openclaw/Peekaboo', '-f', input,
      '-f', `request_id=peekaboo-${tag}-101-2`,
    ]);
    assert.ok(result.calls[2].includes(`.[] | select(.displayTitle == "Update peekaboo for ${tag} (peekaboo-${tag}-101-2)") | .databaseId`));
    assert.deepEqual(result.calls[3], ['run', 'watch', '4321', '--repo', 'openclaw/homebrew-tap', '--exit-status', '--interval', '10']);
  });
}

test('workflow never dispatches a partial, duplicate, or bad-digest inventory', () => {
  for (const assets of [[arm, universal], [intel, universal], [arm, intel, arm], [{ ...arm, digest: null }, intel]]) {
    const result = runHandoff(release(assets));
    assert.notEqual(result.selection.status, 0);
    assert.equal(result.dispatch, undefined);
    assert.equal(result.output, '');
    assert.equal(result.calls.length, 1);
  }
});

test('workflow propagates release API and tap run failures', () => {
  const api = runHandoff(release([arm, intel]), { apiExit: 7 });
  assert.notEqual(api.selection.status, 0);
  assert.equal(api.dispatch, undefined);
  assert.equal(api.calls.length, 1);
  const watch = runHandoff(release([arm, intel]), { watchExit: 8 });
  assert.equal(watch.dispatch.status, 8);
});
