import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';

import {
  REMOVED_ROOT_COMMANDS,
  parseMigrationAdvisorForms,
  parseRegistryCommands,
  validateChangelogContract,
  validateCommandDocsContract,
  validateMigrationGuideContract,
  validateNpmVersionAvailability,
  validateSourceDocumentationContracts,
  validateVersionConsistency,
  validateVersionValues
} from '../scripts/release-preflight-contract.mjs';

const projectRoot = fileURLToPath(new URL('..', import.meta.url));

test('CLI preflight covers all ten removed v4 root commands', () => {
  assert.deepEqual(REMOVED_ROOT_COMMANDS, [
    'image',
    'list',
    'hotkey',
    'inspect-ui',
    'perform-action',
    'swipe',
    'sleep',
    'open',
    'run',
    'commander'
  ]);
});

test('preparation accepts Unreleased while publication requires a dated heading', () => {
  const changelogSource = '# Changelog\n\n## [4.0.0] - Unreleased\n\n- Pending.\n';
  assert.deepEqual(validateChangelogContract({
    changelogSource,
    version: '4.0.0',
    requireDatedHeading: false
  }), []);
  assert.deepEqual(validateChangelogContract({
    changelogSource,
    version: '4.0.0',
    requireDatedHeading: true
  }), ["full publication preflight requires '## [4.0.0] - YYYY-MM-DD'; found Unreleased"]);
});

test('publication accepts only an exact heading with a valid ISO calendar date', () => {
  assert.deepEqual(validateChangelogContract({
    changelogSource: '## [4.0.0] - 2026-08-10\n',
    version: '4.0.0',
    requireDatedHeading: true
  }), []);
  assert.match(validateChangelogContract({
    changelogSource: '### 4.0.0 (2026-08-10)\n',
    version: '4.0.0',
    requireDatedHeading: true
  })[0], /must contain exactly/);
  assert.match(validateChangelogContract({
    changelogSource: '## [4.0.0] - 2026-02-30\n',
    version: '4.0.0',
    requireDatedHeading: true
  })[0], /invalid release date/);
  assert.deepEqual(validateChangelogContract({
    changelogSource: '## [4.0.0] - Unreleased\n\n## [4.0.0] - 2026-08-10\n',
    version: '4.0.0',
    requireDatedHeading: false
  }), [
    "CHANGELOG.md must contain exactly one '## [4.0.0] - Unreleased' or dated ISO heading; found 2"
  ]);
});

test('command registry roots must have exact page, index, and reference parity', () => {
  const registrySource = `
    .init(type: AlphaCommand.self, category: .core),
    .init(type: MenuBarCommand.self, category: .system),
    .init(type: SetValueCommand.self, category: .interaction),
  `;
  assert.deepEqual(parseRegistryCommands(registrySource), ['alpha', 'menubar', 'set-value']);

  const values = {
    registrySource,
    commandPages: ['README.md', 'alpha.md', 'menubar.md', 'set-value.md'],
    indexSource: '[`alpha`](alpha.md) [`menubar`](menubar.md) [`set-value`](set-value.md)',
    referenceSource: '[`alpha`](commands/alpha.md) [`menubar`](commands/menubar.md) ' +
      '[`set-value`](commands/set-value.md)',
    expectedCount: 3
  };
  assert.deepEqual(validateCommandDocsContract(values), []);

  const failures = validateCommandDocsContract({
    ...values,
    commandPages: ['README.md', 'alpha.md', 'menubar.md'],
    referenceSource: '[`alpha`](commands/alpha.md) [`menubar`](commands/menubar.md) ' +
      '[`wrong-label`](commands/set-value.md)'
  });
  assert.ok(failures.some((failure) => failure.includes('docs/commands pages missing: set-value')));
  assert.ok(failures.some((failure) => failure.includes("label 'wrong-label'")));
});

test('migration guide covers every mapping extracted from CommanderMigrationAdvisor', () => {
  const advisorSource = `
    private static let removedRootReplacements: [String: String] = ["hotkey": "press"]
    private static let removedPathReplacements: [String: String] = ["config add": "config credential set"]
    private static let removedOptionReplacements: [String: String] = ["--old": "--new"]
    private static let removedAgentModeReplacements: [String: String] = ["--chat": "agent chat"]
    private static let removedTypeKeyReplacements = Set(["--return"])
  `;
  assert.deepEqual(parseMigrationAdvisorForms(advisorSource), [
    'hotkey', 'config add', '--old', '--chat', '--return'
  ]);

  const removedRootRows = REMOVED_ROOT_COMMANDS.map((command) =>
    `| \`peekaboo ${command} example\` | \`replacement for ${command}\` |`
  );
  const guide = [
    '| Old | New |',
    '|---|---|',
    ...removedRootRows,
    '| `config add value` | `config credential set` |',
    '| `--old` | `--new` |',
    '| `--chat` | `agent chat` |',
    '| `--return` | `press Return` |'
  ].join('\n');
  assert.deepEqual(validateMigrationGuideContract({ advisorSource, migrationGuideSource: guide }), []);

  const failures = validateMigrationGuideContract({
    advisorSource,
    migrationGuideSource: guide.replace('| `--old` | `--new` |', '')
  });
  assert.deepEqual(failures, [
    'docs/v4-migration.md is missing CommanderMigrationAdvisor mappings for: --old'
  ]);
});

test('version parity reports missing and stale release surfaces', () => {
  const failures = validateVersionValues({
    expectedVersion: '4.0.0',
    values: {
      package: '4.0.0',
      CLI: '3.10.0',
      Playground: [],
      Inspector: ['4.0.0', '4.0.0']
    }
  });
  assert.deepEqual(failures, [
    'CLI version mismatch: expected 4.0.0, found 3.10.0',
    'Playground version field is missing'
  ]);
});

test('npm version availability fails closed on failed, empty, and malformed registry responses', () => {
  const request = { packageName: '@steipete/peekaboo', version: '4.2.2' };

  for (const registryOutput of [null, undefined, '', '   ']) {
    assert.match(
      validateNpmVersionAvailability({ ...request, registryOutput })[0],
      /registry query failed or returned no data.*npm view @steipete\/peekaboo versions --json/
    );
  }

  assert.match(
    validateNpmVersionAvailability({ ...request, registryOutput: 'npm ERR! offline' })[0],
    /registry returned invalid JSON/
  );
  for (const registryOutput of ['{}', 'null', '["4.2.0", 422]', '[""]']) {
    assert.match(
      validateNpmVersionAvailability({ ...request, registryOutput })[0],
      /registry returned an invalid version list/
    );
  }
});

test('npm version availability accepts valid registry lists and rejects an already published version', () => {
  const request = { packageName: '@steipete/peekaboo', version: '4.2.2' };

  for (const registryOutput of ['[]', '["4.2.0", "4.2.1"]', '"4.2.0"']) {
    assert.deepEqual(validateNpmVersionAvailability({ ...request, registryOutput }), []);
  }

  for (const registryOutput of ['["4.2.0", "4.2.2"]', '"4.2.2"']) {
    assert.deepEqual(validateNpmVersionAvailability({ ...request, registryOutput }), [
      'Version 4.2.2 is already published on npm!',
      'Please update the version in package.json before releasing.'
    ]);
  }
});

const prepareSource = readFileSync(new URL('../scripts/prepare-release.js', import.meta.url), 'utf8');
const driverSource = readFileSync(new URL('../scripts/release-binaries.sh', import.meta.url), 'utf8');
const sanitizerPath = join(projectRoot, 'scripts/terminal-artifact-env.sh');
const safeTestsFunction = prepareSource.match(/^function runSafeTests\(\) \{[\s\S]*?^\}/m)?.[0];

function safeTestsLaunch() {
  assert.ok(safeTestsFunction, 'test launcher must be inspectable without executing preparation');
  let launch;
  const run = runInNewContext(`${safeTestsFunction}; runSafeTests`, {
    log() {}, colors: {}, join, __dirname: join(projectRoot, 'scripts'), projectRoot,
    spawnSync(command, args, options) {
      launch = { command, args: Array.from(args), options };
      return { status: 0 };
    }
  });
  assert.equal(run(), true);
  assert.equal(launch.command, '/bin/bash');
  assert.deepEqual(launch.args.slice(0, 4), ['--noprofile', '--norc', '-p', '-c']);
  assert.deepEqual(launch.args.slice(5), ['peekaboo-release-tests', sanitizerPath, 'pnpm', 'test']);
  assert.equal(launch.options.cwd, projectRoot);
  assert.equal(launch.options.stdio, 'inherit');
  return launch;
}

function environmentFixture(t) {
  const root = mkdtempSync('/tmp/peekaboo preflight env ');
  const rejectedTool = `peekaboo-rejected-${root.slice(-6)}`;
  const absentTool = `peekaboo-absent-${root.slice(-6)}`;
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const dir of ['home', 'tmp', 'scripts', 'signing-shim']) mkdirSync(join(root, dir));
  const write = (path, text) => writeFileSync(join(root, path), text);
  write('startup', 'printf "unexpected startup\\n" > "$HOME/startup-ran"\n');
  for (const tool of ['node', 'pnpm', 'npm', 'python3', 'git', 'codesign', 'bash', rejectedTool]) {
    write(`signing-shim/${tool}`, '#!/bin/bash\nprintf "unexpected shim\\n" > "$HOME/shim-ran"\nexit 98\n');
    chmodSync(join(root, `signing-shim/${tool}`), 0o755);
  }
  write('signing-shim/codesign', `#!/bin/bash -p
set -euo pipefail
source "$FIXTURE_SANITIZER"
for name in "\${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
  case "$name" in
    DYLD_*) [[ -z "\${!name+x}" ]] ;;
    BASH_ENV|ENV) [[ "\${!name}" == "$PWD/startup" ]] ;;
    *) [[ "\${!name}" == sentinel ]] ;;
  esac
done
[[ "$MAC_RELEASE_CODESIGN_KEYCHAIN" == "$HOME/keychain" && "$CODESIGN_KEYCHAIN" == "$HOME/keychain" ]]
[[ "$CODESIGN_IDENTITY" == fixture ]]
[[ "$PEEKABOO_OP_SERVICE_TOKEN_FILE" == "$HOME/primary" && "$PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE" == "$HOME/legacy" ]]
printf 'later-signing-child-authority-retained=true\\n'
`);
  write('probe', `#!/bin/bash
set -euo pipefail
source "$FIXTURE_SANITIZER"
assertion=protected-variables
trap 'printf "preflight-probe: assertion=%s tool=%s exit=%s\\n" "$assertion" "\${tool:-none}" "$?" >&2' ERR
terminal_artifact_assert_build_env_is_clean
for name in MAC_RELEASE_CODESIGN_KEYCHAIN CODESIGN_KEYCHAIN CODESIGN_IDENTITY \\
  PEEKABOO_OP_SERVICE_TOKEN_FILE PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE CDPATH GLOBIGNORE BASH_FUNC_fixture; do
  assertion="unset-$name"
  [[ -z "\${!name+x}" ]]
done
assertion=exact-trusted-path
[[ "$PATH" == /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ]]
assertion=allowed-values
[[ "$SWIFTPM_MIRROR_CONFIG" == "$HOME/verified-source-mapping.json" ]]
[[ "$DEVELOPER_DIR" == "$HOME/developer" && "$PEEKABOO_USE_RESOLVED_VERSIONS" == 1 ]]
assertion=tool-resolution
for tool in node pnpm npm python3 git codesign bash ${rejectedTool} ${absentTool}; do
  # Safe refusal is not evidence that a required build command is installed.
  if resolved="$(command -v "$tool")"; then
    case "$resolved" in
      /opt/homebrew/bin/*|/usr/local/bin/*|/usr/bin/*|/bin/*) ;;
      *) printf 'preflight-probe: tool=%s unsafe-resolution\\n' "$tool" >&2; exit 92 ;;
    esac
    [[ "$tool" != peekaboo-rejected-* && "$tool" != peekaboo-absent-* ]]
    printf 'tool=%s resolution=trusted\\n' "$tool"
  else
    lookup_exit=$?
    [[ "$lookup_exit" == 1 && "$tool" != bash ]]
    printf 'tool=%s resolution=unavailable safe-refusal=true\\n' "$tool"
  fi
done
assertion=arguments
[[ "$#" == 4 && "$1" == 'argument one' && "$2" == 'quote" and $literal' && -z "$3" && "$4" == $'line one\\nline two' ]]
printf 'test-child-clean=true tool-boundary-safe=true arguments-preserved=true\\n'
exit "$FIXTURE_CHILD_EXIT"
`);
  chmodSync(join(root, 'probe'), 0o755);
  // Seed only synthetic values, after Bash has started. The protected-name list
  // comes from its owner; no copied JavaScript credential list or operator env.
  const prelude = `set -euo pipefail
source "$FIXTURE_SANITIZER"
export RELEASE_PREFLIGHT_COMPLETED=false RELEASE_PUBLICATION_ELIGIBLE=false
export MAC_RELEASE_CODESIGN_KEYCHAIN="$HOME/keychain" CODESIGN_KEYCHAIN="$HOME/keychain" CODESIGN_IDENTITY=fixture
export SWIFTPM_MIRROR_CONFIG="$HOME/verified-source-mapping.json" DEVELOPER_DIR="$HOME/developer"
export PEEKABOO_USE_RESOLVED_VERSIONS=1
export PEEKABOO_OP_SERVICE_TOKEN_FILE="$HOME/primary" PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE="$HOME/legacy"
export CDPATH=sentinel GLOBIGNORE=sentinel BASH_FUNC_fixture=sentinel
for name in "\${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
  printf -v "$name" sentinel
  export "$name"
done
export BASH_ENV="$PWD/startup" ENV="$PWD/startup"
export PATH="$PWD/signing-shim:$PATH"
parent_path="$PATH"
[[ "$(command -v codesign)" == "$PWD/signing-shim/codesign" ]]
[[ "$(command -v ${rejectedTool})" == "$PWD/signing-shim/${rejectedTool}" ]]
if command -v ${absentTool} >/dev/null; then exit 94; fi
check_parent() {
  local result=$? name
  for name in "\${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
    case "$name" in
      BASH_ENV|ENV) [[ "\${!name}" == "$PWD/startup" ]] || exit 93 ;;
      *) [[ "\${!name}" == sentinel ]] || exit 93 ;;
    esac
  done
  [[ "$PATH" == "$parent_path" && "$(command -v codesign)" == "$PWD/signing-shim/codesign" ]]
  [[ "$MAC_RELEASE_CODESIGN_KEYCHAIN" == "$HOME/keychain" && "$CODESIGN_KEYCHAIN" == "$HOME/keychain" && "$CODESIGN_IDENTITY" == fixture ]]
  [[ "$PEEKABOO_OP_SERVICE_TOKEN_FILE" == "$HOME/primary" && "$PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE" == "$HOME/legacy" ]]
  (
    trap - EXIT
    # Only this fake signing child sheds loader poison; the parent retains it.
    for name in "\${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
      case "$name" in DYLD_*) builtin unset "$name" ;; esac
    done
    for name in "\${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
      case "$name" in
        DYLD_*) [[ -z "\${!name+x}" ]] || { printf 'signing pre-native variable remains: %s\\n' "$name" >&2; exit 91; } ;;
      esac
    done
    codesign # Only the asserted fixture shim; it checks synthetic authority.
  )
  for name in "\${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
    case "$name" in DYLD_*) [[ "\${!name}" == sentinel ]] || exit 93 ;; esac
  done
  [[ ! -e "$HOME/startup-ran" ]]
  [[ ! -e "$HOME/shim-ran" ]]
  printf 'parent-retained=true preflight=%s eligible=%s exit=%s\\n' "$RELEASE_PREFLIGHT_COMPLETED" "$RELEASE_PUBLICATION_ELIGIBLE" "$result"
  exit "$result"
}
trap check_parent EXIT
`;
  return {
    root, write, prelude, rejectedTool, absentTool,
    env: {
      PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin',
      HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'), LANG: 'C',
      // Harmless hooks exercise the protected startup prefix; DYLD is seeded later.
      BASH_ENV: join(root, 'startup'), ENV: join(root, 'startup'),
      FIXTURE_SANITIZER: sanitizerPath, FIXTURE_PROBE: join(root, 'probe')
    },
    probeArgs: ['argument one', 'quote" and $literal', '', 'line one\nline two']
  };
}

test('direct preparation test launcher preserves child exits and refuses unavailable commands', (t) => {
  const launch = safeTestsLaunch();
  const fixture = environmentFixture(t);
  // Run the captured body after interpreter startup, retaining its $0/$1... argv.
  // A shell subshell isolates body cleanup without another poisoned native entry.
  const directBody = `${fixture.prelude}
/usr/bin/env() {
  local name
  for name in "\${TERMINAL_ARTIFACT_SECRET_NAMES[@]}" CDPATH GLOBIGNORE BASH_FUNC_fixture \\
    MAC_RELEASE_CODESIGN_KEYCHAIN CODESIGN_KEYCHAIN CODESIGN_IDENTITY \\
    PEEKABOO_OP_SERVICE_TOKEN_FILE PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE; do
    [[ -z "\${!name+x}" ]] || { printf 'direct pre-native variable remains: %s\\n' "$name" >&2; return 91; }
  done
  printf 'direct-pre-native-clean=true\\n'
  command /usr/bin/env "$@"
}
(
  # The parent's EXIT trap must not inspect the body's scrubbed BASH_ENV/ENV.
  trap - EXIT
${launch.args[4]}
)
`;
  const args = [...launch.args.slice(0, 4), directBody, ...launch.args.slice(5, -2)];
  for (const childExit of [0, 37]) {
    const result = spawnSync(launch.command, [...args, fixture.env.FIXTURE_PROBE, ...fixture.probeArgs], {
      cwd: fixture.root, env: { ...fixture.env, FIXTURE_CHILD_EXIT: String(childExit) }, encoding: 'utf8'
    });
    t.diagnostic(JSON.stringify({ lane: 'direct', childExit, status: result.status,
      stdout: result.stdout, stderr: result.stderr }));
    assert.equal(result.status, childExit, result.stdout + result.stderr);
    assert.equal(result.stderr, '');
    assert.match(result.stdout, /direct-pre-native-clean=true/);
    assert.match(result.stdout, /test-child-clean=true tool-boundary-safe=true arguments-preserved=true/);
    assert.match(result.stdout, /tool=bash resolution=trusted/);
    for (const tool of [fixture.rejectedTool, fixture.absentTool]) {
      assert.ok(result.stdout.includes(`tool=${tool} resolution=unavailable safe-refusal=true`));
    }
    assert.match(result.stdout, /later-signing-child-authority-retained=true/);
    assert.match(result.stdout, new RegExp(`parent-retained=true preflight=false eligible=false exit=${childExit}`));
  }
  for (const command of [fixture.rejectedTool, fixture.absentTool]) {
    const result = spawnSync(launch.command, [...args, command, 'test'], {
      cwd: fixture.root, env: fixture.env, encoding: 'utf8'
    });
    t.diagnostic(JSON.stringify({ lane: 'direct', command, status: result.status,
      stdout: result.stdout, stderr: result.stderr }));
    assert.equal(result.status, 127, result.stdout + result.stderr);
    assert.ok(result.stderr.includes(command), 'missing-command diagnostic names the tool');
    assert.match(result.stdout, /direct-pre-native-clean=true/);
    assert.doesNotMatch(result.stdout, /test-child-clean=true/);
    assert.match(result.stdout, /later-signing-child-authority-retained=true/);
    assert.match(result.stdout, /parent-retained=true preflight=false eligible=false exit=127/);
    assert.equal(existsSync(join(fixture.root, 'home/shim-ran')), false);
  }
  t.diagnostic('direct scenarios completed: 4');
});

test('actual driver preflight gate sanitizes normal and reuse commands before eligibility', (t) => {
  const fixture = environmentFixture(t);
  safeTestsLaunch();
  const gate = driverSource.split('# Step 1: Run pre-release checks (unless skipped)\n')[1]
    ?.split('\nassert_release_plan\n')[0];
  const eligibility = driverSource.match(/^if \[\[ "\$CREATE_GITHUB_RELEASE" == true && "\$PUBLISH_NPM" == true &&\n[\s\S]*?^fi/m)?.[0];
  assert.ok(gate && eligibility, 'exercise the actual gate and eligibility block, without running the release driver');
  assert.match(driverSource, /^RELEASE_PREFLIGHT_COMPLETED=false\nRELEASE_PUBLICATION_ELIGIBLE=false$/m);
  assert.match(driverSource, /source "\$SCRIPT_DIR\/terminal-artifact-env.sh"/);
  assert.match(gate, /terminal_artifact_run_build \/usr\/bin\/env/);
  assert.doesNotMatch(gate, /setup-swift-workspace/);
  assert.match(prepareSource, /if \(!runSafeTests\(\)\)/);
  fixture.write('package.json', '{"type":"module"}\n');
  fixture.write('scripts/prepare-release.js', `
import assert from 'node:assert/strict';
import { spawnSync as realSpawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
const __dirname = dirname(process.env.FIXTURE_SANITIZER);
const projectRoot = process.cwd();
const colors = {};
function log() {}
const protectedNames = readFileSync(process.env.FIXTURE_SANITIZER, 'utf8')
  .match(/TERMINAL_ARTIFACT_SECRET_NAMES=\\(([\\s\\S]*?)\\)/)[1].trim().split(/\\s+/);
for (const name of [...protectedNames, 'PEEKABOO_OP_SERVICE_TOKEN_FILE', 'PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE']) {
  assert.equal(process.env[name], undefined, name);
}
assert.equal(process.env.PATH, '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin');
assert.equal(process.env.RELEASE_PREFLIGHT_COMPLETED, 'false');
assert.equal(process.env.RELEASE_PUBLICATION_ELIGIBLE, 'false');
assert.equal(process.env.PEEKABOO_REQUIRE_UNIVERSAL, '1');
assert.equal(process.env.MAC_RELEASE_CODESIGN_IDENTITY, 'fixture-release-identity');
assert.deepEqual(process.argv.slice(2), process.env.FIXTURE_REUSE === 'true'
  ? ['--no-build', '--bin', join(projectRoot, 'peekaboo')] : []);
const original = { ...process.env };
function spawnSync(command, args, options) {
  assert.deepEqual(args.slice(-2), ['pnpm', 'test']);
  return realSpawnSync(command, [...args.slice(0, -2), process.env.FIXTURE_PROBE,
    ...${JSON.stringify(fixture.probeArgs)}], options);
}
${safeTestsFunction}
const passed = runSafeTests();
assert.deepEqual({ ...process.env }, original);
assert.equal(process.env.MAC_RELEASE_CODESIGN_KEYCHAIN, join(process.env.HOME, 'keychain'));
assert.equal(process.env.CODESIGN_KEYCHAIN, join(process.env.HOME, 'keychain'));
assert.equal(process.env.CODESIGN_IDENTITY, 'fixture');
console.log('preflight-build-authority-retained=true');
process.exit(passed ? 0 : 37);
`);
  fixture.write('gate.sh', `${fixture.prelude}
# Observe the real sanitizer before native exec; dispatch only the fixture's
# Node argv through the running test interpreter (or a missing fixture command).
# This avoids depending on an installed Node on the production PATH.
/usr/bin/env() {
  local name arg replacements=0
  local -a forwarded=()
  for name in "\${TERMINAL_ARTIFACT_SECRET_NAMES[@]}" CDPATH GLOBIGNORE BASH_FUNC_fixture \\
    PEEKABOO_OP_SERVICE_TOKEN_FILE PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE; do
    [[ -z "\${!name+x}" ]] || { printf 'pre-native variable remains: %s\\n' "$name" >&2; return 91; }
  done
  for arg in "$@"; do
    if [[ "$arg" == node ]]; then
      forwarded+=("$FIXTURE_GATE_COMMAND")
      replacements=$((replacements + 1))
    else
      forwarded+=("$arg")
    fi
  done
  [[ "$replacements" == 1 ]] || { printf 'fixture Node dispatch missing\\n' >&2; return 92; }
  printf 'gate-pre-native-clean=true fixture-node-dispatch=true\\n'
  command /usr/bin/env "\${forwarded[@]}"
}
SKIP_CHECKS=false UNIVERSAL=true REUSE_BUILT_CLI="$FIXTURE_REUSE"
PROJECT_ROOT="$PWD" CLI_SIGN_IDENTITY=fixture-release-identity
CREATE_GITHUB_RELEASE=true PUBLISH_NPM=true
BLUE='' RED='' GREEN='' NC=''
${gate}
${eligibility}
`);
  for (const reuse of ['false', 'true']) {
    for (const childExit of [0, 37]) {
      const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-p', 'gate.sh'], {
        cwd: fixture.root, encoding: 'utf8',
        env: { ...fixture.env, FIXTURE_REUSE: reuse, FIXTURE_CHILD_EXIT: String(childExit),
          FIXTURE_GATE_COMMAND: process.execPath }
      });
      t.diagnostic(JSON.stringify({ lane: 'driver-gate', reuse, childExit, status: result.status,
        stdout: result.stdout, stderr: result.stderr }));
      // The sanitizer preserves 37; the existing driver deliberately maps a
      // failed complete preflight to release exit 1 and never grants eligibility.
      assert.equal(result.status, childExit === 0 ? 0 : 1, result.stdout + result.stderr);
      assert.equal(result.stderr, '');
      assert.match(result.stdout, /gate-pre-native-clean=true fixture-node-dispatch=true/);
      assert.match(result.stdout, /test-child-clean=true tool-boundary-safe=true arguments-preserved=true/);
      assert.match(result.stdout, /preflight-build-authority-retained=true/);
      assert.match(result.stdout, /later-signing-child-authority-retained=true/);
      assert.match(result.stdout, childExit === 0
        ? /parent-retained=true preflight=true eligible=true exit=0/
        : /parent-retained=true preflight=false eligible=false exit=1/);
    }
    for (const command of [fixture.rejectedTool, fixture.absentTool]) {
      const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-p', 'gate.sh'], {
        cwd: fixture.root, encoding: 'utf8',
        env: { ...fixture.env, FIXTURE_REUSE: reuse, FIXTURE_GATE_COMMAND: command }
      });
      t.diagnostic(JSON.stringify({ lane: 'driver-gate', reuse, command, status: result.status,
        stdout: result.stdout, stderr: result.stderr }));
      assert.equal(result.status, 1, result.stdout + result.stderr);
      assert.ok(result.stderr.includes(command), 'missing-command diagnostic names the tool');
      assert.match(result.stdout, /gate-pre-native-clean=true fixture-node-dispatch=true/);
      assert.doesNotMatch(result.stdout, /test-child-clean=true|preflight-build-authority-retained=true/);
      assert.match(result.stdout, /later-signing-child-authority-retained=true/);
      assert.match(result.stdout, /parent-retained=true preflight=false eligible=false exit=1/);
      assert.equal(existsSync(join(fixture.root, 'home/shim-ran')), false);
    }
  }
  t.diagnostic('driver-gate scenarios completed: 8');
});

test('repository release source surfaces remain internally consistent', () => {
  const packageVersion = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;
  const versionResult = validateVersionConsistency(projectRoot);
  assert.equal(versionResult.version, packageVersion);
  assert.deepEqual(versionResult.failures, []);
  assert.deepEqual(validateSourceDocumentationContracts(projectRoot), []);
});
