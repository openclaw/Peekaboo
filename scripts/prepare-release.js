#!/usr/bin/env node

/**
 * Release preparation script for @steipete/peekaboo
 * 
 * This script performs comprehensive checks before release:
 * 1. Git status checks (branch, uncommitted files, sync with origin)
 * 2. Metadata and documentation contract checks
 * 3. Swift checks (format, lint, tests)
 * 4. Build, CLI contract, and package verification
 */

import { execSync, spawnSync } from 'child_process';
import { readFileSync, existsSync } from 'fs';
import { dirname, isAbsolute, join, resolve } from 'path';
import { fileURLToPath } from 'url';
import {
  MIGRATION_ADVISOR_PATH,
  REMOVED_ROOT_COMMANDS,
  parseRemovedRootReplacements,
  validateChangelogContract,
  validateNpmVersionAvailability,
  validateSourceDocumentationContracts,
  validateVersionConsistency
} from './release-preflight-contract.mjs';
import { validateTrackedReleaseNotes } from './release-driver-contract.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = join(__dirname, '..');
const cliArguments = process.argv.slice(2);
let dryRun = false;
let force = false;
let binaryOverride = null;
let noBuild = false;

for (let index = 0; index < cliArguments.length; index += 1) {
  const argument = cliArguments[index];
  switch (argument) {
    case '--':
      break;
    case '--dry-run':
      dryRun = true;
      break;
    case '--force':
      force = true;
      break;
    case '--no-build':
      noBuild = true;
      break;
    case '--bin': {
      const value = cliArguments[index + 1];
      if (!value) {
        console.error('--bin requires a path');
        process.exit(2);
      }
      binaryOverride = isAbsolute(value) ? value : resolve(projectRoot, value);
      index += 1;
      break;
    }
    case '-h':
    case '--help':
      console.log(`Usage: node scripts/prepare-release.js [options]

Options:
  --dry-run   Run deterministic preparation checks; changelogs may remain Unreleased
  --bin PATH  CLI binary for --dry-run or --no-build (default: repo debug binary, then ./peekaboo)
  --no-build  Run full publication preflight without replacing the supplied CLI binary
  --force     Allow a non-main branch during the publication-stage preflight
  -h, --help  Show this help`);
      process.exit(0);
      break;
    default:
      console.error(`Unknown option: ${argument}`);
      process.exit(2);
  }
}

if (noBuild && !binaryOverride) {
  console.error('--no-build requires --bin PATH');
  process.exit(2);
}

// ANSI color codes
const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  cyan: '\x1b[36m'
};

function log(message, color = '') {
  console.log(`${color}${message}${colors.reset}`);
}

function logStep(step) {
  console.log(`\n${colors.bright}${colors.blue}━━━ ${step} ━━━${colors.reset}\n`);
}

function logSuccess(message) {
  log(`✅ ${message}`, colors.green);
}

function logError(message) {
  log(`❌ ${message}`, colors.red);
}

function logWarning(message) {
  log(`⚠️  ${message}`, colors.yellow);
}

function exec(command, options = {}) {
  try {
    return execSync(command, {
      cwd: projectRoot,
      stdio: 'pipe',
      encoding: 'utf8',
      ...options
    }).trim();
  } catch (error) {
    if (options.allowFailure) {
      return null;
    }
    throw error;
  }
}

function npmEnv() {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (key.toLowerCase().startsWith('npm_config_')) {
      delete env[key];
    }
  }
  return env;
}

function execNpm(command, options = {}) {
  return exec(command, {
    env: npmEnv(),
    ...options
  });
}

function execWithOutput(command, description) {
  try {
    log(`Running: ${description}...`, colors.cyan);
    execSync(command, {
      cwd: projectRoot,
      stdio: 'inherit'
    });
    return true;
  } catch (error) {
    return false;
  }
}

// Check functions
function checkGitStatus() {
  logStep('Git Status Checks');

  // Check current branch
  const currentBranch = exec('git branch --show-current');
  if (currentBranch !== 'main') {
    logWarning(`Currently on branch '${currentBranch}', not 'main'`);
    if (!force) {
      logError('Switch to main branch before releasing (use --force to override)');
      return false;
    }
  } else {
    logSuccess('On main branch');
  }

  // Check for uncommitted changes
  const gitStatus = exec('git status --porcelain');
  if (gitStatus) {
    logError('Uncommitted changes detected:');
    console.log(gitStatus);
    return false;
  }
  logSuccess('No uncommitted changes');

  // Check if up to date with origin
  exec('git fetch');
  const behind = exec('git rev-list HEAD..origin/main --count');
  const ahead = exec('git rev-list origin/main..HEAD --count');
  
  if (behind !== '0') {
    logError(`Branch is ${behind} commits behind origin/main`);
    return false;
  }
  if (ahead !== '0') {
    logWarning(`Branch is ${ahead} commits ahead of origin/main (remember to push after release)`);
  } else {
    logSuccess('Branch is up to date with origin/main');
  }

  return true;
}

function checkDependencies() {
  logStep('Dependency Checks');

  // Check if node_modules exists
  if (!existsSync(join(projectRoot, 'node_modules'))) {
    log('Installing dependencies with pnpm...', colors.yellow);
    if (!execWithOutput('pnpm install --frozen-lockfile', 'pnpm install')) {
      logError('Failed to install dependencies');
      return false;
    }
  }
  
  logSuccess('Dependencies checked');
  return true;
}

function checkDocs() {
  logStep('Documentation Contract Checks');
  if (!execWithOutput('node scripts/docs-lint.mjs', 'documentation lint')) {
    logError('Documentation contract checks failed');
    return false;
  }
  let failures;
  try {
    failures = validateSourceDocumentationContracts(projectRoot);
  } catch (error) {
    logError(`Could not inspect release source contracts: ${error.message}`);
    return false;
  }
  if (failures.length > 0) {
    logError('Release source/documentation parity checks failed:');
    failures.forEach((failure) => logError(`  - ${failure}`));
    return false;
  }
  logSuccess('Documentation and release source contracts passed');
  return true;
}

function runSafeTests() {
  log('Running: Swift CLI tests (safe)...', colors.cyan);
  const result = spawnSync('/bin/bash', [
    '--noprofile', '--norc', '-p', '-c',
    `set -euo pipefail
source "$1"
shift
builtin unset MAC_RELEASE_CODESIGN_KEYCHAIN CODESIGN_KEYCHAIN CODESIGN_IDENTITY
terminal_artifact_run_build "$@"`,
    'peekaboo-release-tests',
    join(__dirname, 'terminal-artifact-env.sh'),
    'pnpm', 'test'
  ], { cwd: projectRoot, stdio: 'inherit' });
  return result.status === 0;
}

function checkSwift() {
  logStep('Swift Checks');

  // Run SwiftFormat
  if (!execWithOutput('pnpm run format:swift', 'SwiftFormat')) {
    logError('SwiftFormat failed');
    return false;
  }
  logSuccess('SwiftFormat completed');

  // Check if SwiftFormat made any changes
  const formatChanges = exec('git status --porcelain');
  if (formatChanges) {
    logError('SwiftFormat made changes. Please commit them before releasing:');
    console.log(formatChanges);
    return false;
  }

  // Run SwiftLint
  if (!execWithOutput('pnpm run lint:swift', 'SwiftLint')) {
    logError('SwiftLint found violations');
    return false;
  }
  logSuccess('SwiftLint passed');

  // Check for Swift compiler warnings/errors
  log('Checking for Swift compiler warnings...', colors.cyan);
  let swiftBuildOutput = '';
  try {
    // Capture build output to check for warnings. Start from a clean SwiftPM
    // state so an interrupted release build cannot poison the next preflight.
    swiftBuildOutput = execSync('python3 scripts/setup-swift-workspace.py setup && cd Apps/CLI && swift package reset && python3 ../../scripts/setup-swift-workspace.py run --release -- swift build --arch arm64 -c release 2>&1', {
      cwd: projectRoot,
      encoding: 'utf8',
      timeout: 600_000
    });
  } catch (error) {
    logError('Swift build failed during analyzer check');
    if (error.stdout) console.log(error.stdout);
    if (error.stderr) console.log(error.stderr);
    return false;
  }

  // Check for warnings in the output
  const warningMatches = swiftBuildOutput.match(/warning:|note:/gi);
  if (warningMatches && warningMatches.length > 0) {
    logWarning(`Found ${warningMatches.length} warnings/notes in Swift build`);
    // Extract and show warning lines
    const lines = swiftBuildOutput.split('\n');
    lines.forEach(line => {
      if (line.includes('warning:') || line.includes('note:')) {
        console.log(`  ${line.trim()}`);
      }
    });
  } else {
    logSuccess('No Swift compiler warnings found');
  }

  // Remove keychain locators only for tests; the later CLI build still signs.
  if (!runSafeTests()) {
    logError('Swift tests failed');
    return false;
  }
  logSuccess('Swift tests passed');

  return true;
}

function checkVersionAvailability() {
  logStep('Version Availability Check');

  const packageJson = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
  const packageName = packageJson.name;
  const version = packageJson.version;

  log(`Checking if ${packageName}@${version} is already published...`, colors.cyan);

  const existingVersions = execNpm(`npm view ${packageName} versions --json`, { allowFailure: true });
  const failures = validateNpmVersionAvailability({
    packageName,
    version,
    registryOutput: existingVersions
  });
  if (failures.length > 0) {
    failures.forEach(logError);
    return false;
  }

  logSuccess(`Version ${version} is available for publishing`);
  return true;
}

function checkChangelog() {
  logStep('Changelog Entry Check');

  const packageJson = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
  const version = packageJson.version;

  for (const relativePath of ['CHANGELOG.md', 'Apps/CLI/CHANGELOG.md']) {
    const changelogPath = join(projectRoot, relativePath);
    if (!existsSync(changelogPath)) {
      logError(`${relativePath} not found`);
      return false;
    }

    const failures = validateChangelogContract({
      changelogSource: readFileSync(changelogPath, 'utf8'),
      version,
      requireDatedHeading: !dryRun
    });
    if (failures.length > 0) {
      failures.forEach((failure) => logError(`${relativePath}: ${failure}`));
      return false;
    }
  }

  if (!dryRun) {
    try {
      validateTrackedReleaseNotes({
        changelog: readFileSync(join(projectRoot, 'CHANGELOG.md'), 'utf8'),
        notes: readFileSync(join(projectRoot, 'release', 'release-notes.md'), 'utf8'),
        version,
      });
    } catch (error) {
      logError(`release/release-notes.md: ${error.message}`);
      return false;
    }
  }

  if (dryRun) {
    logSuccess(`Both changelogs contain a preparation-stage entry for version ${version}`);
  } else {
    logSuccess(`Both changelogs contain a dated publication entry for version ${version}`);
  }
  return true;
}

function checkPackageSize() {
  logStep('Package Size Check');

  // Create a temporary package to get accurate size
  log('Calculating package size...', colors.cyan);
  const packOutput = execNpm('npm pack --dry-run 2>&1');
  
  // Extract size information
  const unpackedMatch = packOutput.match(/unpacked size: ([^\n]+)/);
  
  if (unpackedMatch) {
    const sizeStr = unpackedMatch[1];
    
    // Convert to bytes for comparison
    let sizeInBytes = 0;
    if (sizeStr.includes('MB')) {
      sizeInBytes = parseFloat(sizeStr) * 1024 * 1024;
    } else if (sizeStr.includes('kB')) {
      sizeInBytes = parseFloat(sizeStr) * 1024;
    } else if (sizeStr.includes('B')) {
      sizeInBytes = parseFloat(sizeStr);
    }
    
    const maxSizeInBytes = 64 * 1024 * 1024; // Includes the bundled universal Swift CLI binary.
    
    if (sizeInBytes > maxSizeInBytes) {
      logWarning(`Package size (${sizeStr}) exceeds 64MB threshold`);
      logWarning('Consider reviewing included files to reduce package size');
    } else {
      logSuccess(`Package size (${sizeStr}) is within acceptable limits`);
    }
  } else {
    logWarning('Could not determine package size');
  }
  
  return true;
}

function checkSwiftCLIIntegration(binaryPath) {
  logStep('Swift CLI Contract Tests');

  if (!existsSync(binaryPath)) {
    logError(`Peekaboo binary not found: ${binaryPath}`);
    return false;
  }

  const run = (args) => spawnSync(binaryPath, args, {
    cwd: projectRoot,
    encoding: 'utf8',
    stdio: 'pipe'
  });
  const combinedOutput = (result) => `${result.stdout || ''}\n${result.stderr || ''}`;

  const invalid = run(['invalid-command']);
  if (invalid.status === 0 || !combinedOutput(invalid).includes("Unknown command 'invalid-command'")) {
    logError('Unknown commands must fail with the Commander unknown-command diagnostic');
    return false;
  }

  // Removed roots must fail and name their exact v4 replacement, even when a
  // trailing --help would otherwise short-circuit into help output. Matching only
  // the hint prefix would pass on an empty or wrong replacement.
  let removedReplacements;
  try {
    removedReplacements = parseRemovedRootReplacements(
      readFileSync(join(projectRoot, MIGRATION_ADVISOR_PATH), 'utf8')
    );
  } catch (error) {
    logError(`Could not read removed-command replacements: ${error.message}`);
    return false;
  }
  for (const command of REMOVED_ROOT_COMMANDS) {
    const replacement = removedReplacements.get(command);
    if (!replacement) {
      logError(`No advisor replacement declared for removed command: peekaboo ${command}`);
      return false;
    }
    const result = run([command, '--help']);
    if (result.status === 0) {
      logError(`Removed command unexpectedly resolved: peekaboo ${command}`);
      return false;
    }
    const expected = `Command 'peekaboo ${command}' was removed in v4. Use '${replacement}'.`;
    if (!combinedOutput(result).includes(expected)) {
      logError(`Removed command lacks its exact v4 migration hint: peekaboo ${command}`);
      return false;
    }
  }

  const helpContracts = [
    { args: ['see', '--help'], required: ['--no-elements', '--tree', '--no-screenshot'] },
    { args: ['click', '--help'], required: ['--at', '--wait-for', '--long-press'] },
    { args: ['press', '--help'], required: ['--delay', '--hold', 'cmd+shift+t'] },
    { args: ['action', '--help'], required: ['AXPress', '--on'] },
    { args: ['drag', '--help'], required: ['--from', '--to', '--button', '--duration'] },
    { args: ['move', '--help'], required: ['--at', '--on', '--foreground'] },
    { args: ['app', 'list', '--help'], required: ['peekaboo app list', '--include-hidden'] },
    { args: ['window', 'list', '--help'], required: ['peekaboo window list', '--group-by-space'] },
    { args: ['screen', 'list', '--help'], required: ['peekaboo screen list'] }
  ];
  const staleHelp = [
    'peekaboo image',
    'peekaboo list apps',
    'peekaboo list windows',
    'peekaboo hotkey',
    'peekaboo inspect-ui',
    'peekaboo perform-action',
    'peekaboo swipe',
    '--coords',
    '--from-coords',
    '--to-coords'
  ];

  for (const contract of helpContracts) {
    const result = run(contract.args);
    const output = combinedOutput(result);
    if (result.status !== 0 || !contract.required.every((token) => output.includes(token))) {
      logError(`CLI help contract failed: peekaboo ${contract.args.join(' ')}`);
      return false;
    }
    const stale = staleHelp.find((token) => output.includes(token));
    if (stale) {
      logError(`CLI help contains removed form '${stale}': peekaboo ${contract.args.join(' ')}`);
      return false;
    }
  }

  const jsonContracts = [
    { args: ['app', 'list', '--json', '--no-remote'], field: 'apps' },
    { args: ['window', 'list', '--app', 'Finder', '--json', '--no-remote'], field: 'windows' },
    { args: ['screen', 'list', '--json', '--no-remote'], field: 'screens' }
  ];
  for (const contract of jsonContracts) {
    const result = run(contract.args);
    try {
      const payload = JSON.parse(result.stdout);
      if (result.status !== 0 || payload.success !== true || !(contract.field in payload.data)) {
        throw new Error(`missing data.${contract.field}`);
      }
    } catch (error) {
      logError(`CLI JSON contract failed for '${contract.args.join(' ')}': ${error.message}`);
      return false;
    }
  }

  logSuccess('Swift CLI v4 command, help, and inventory contracts passed');
  return true;
}

function checkVersionConsistency() {
  logStep('Version Consistency Check');
  let result;
  try {
    result = validateVersionConsistency(projectRoot);
  } catch (error) {
    logError(`Could not inspect version surfaces: ${error.message}`);
    return false;
  }
  if (result.failures.length > 0) {
    result.failures.forEach((failure) => logError(failure));
    return false;
  }
  logSuccess(`Version ${result.version} matches every release source surface`);
  return true;
}

function checkRequiredFields() {
  logStep('Required Fields Validation');

  const packageJson = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
  
  const requiredFields = {
    'name': 'Package name',
    'version': 'Package version',
    'description': 'Package description',
    'main': 'Main entry point',
    'type': 'Module type',
    'bin': 'CLI entry points',
    'scripts': 'Scripts section',
    'repository': 'Repository information',
    'keywords': 'Keywords for npm search',
    'author': 'Author information',
    'license': 'License',
    'engines': 'Node.js engine requirements',
    'files': 'Files to include in package'
  };
  
  const missingFields = [];
  
  for (const [field, description] of Object.entries(requiredFields)) {
    if (!packageJson[field]) {
      missingFields.push(`${field} (${description})`);
    }
  }
  
  if (missingFields.length > 0) {
    logError('Missing required fields in package.json:');
    missingFields.forEach(field => logError(`  - ${field}`));
    return false;
  }
  
  // Additional validations
  if (!packageJson.repository || typeof packageJson.repository !== 'object' || !packageJson.repository.url) {
    logError('Repository field must be an object with a url property');
    return false;
  }
  
  if (!Array.isArray(packageJson.keywords) || packageJson.keywords.length === 0) {
    logWarning('Keywords array is empty. Consider adding keywords for better discoverability');
  }
  
  if (!packageJson.engines || !packageJson.engines.node) {
    logError('Missing engines.node field to specify Node.js version requirements');
    return false;
  }
  
  logSuccess('All required fields are present in package.json');
  return true;
}

function buildAndVerifyPackage() {
  logStep('Build and Package Verification');

  const requireUniversal = process.env.PEEKABOO_REQUIRE_UNIVERSAL === '1';
  const buildScript = requireUniversal ? './scripts/build-swift-universal.sh' : './scripts/build-swift-arm.sh';
  const buildLabel = requireUniversal ? 'Swift universal build' : 'Swift arm64 build';

  if (noBuild) {
    log(`Reusing source-identical CLI without rebuilding: ${binaryOverride}`, colors.cyan);
  } else {
    // Build Swift binary (stamps Info.plist and writes ./peekaboo)
    if (!execWithOutput(buildScript, buildLabel)) {
      logError('Swift build failed');
      return false;
    }
    logSuccess('Swift build completed successfully');
  }

  // Create package
  log('Creating npm package...', colors.cyan);
  const packOutput = execNpm('npm pack --dry-run 2>&1');
  
  // Parse package details
  const sizeMatch = packOutput.match(/package size: ([^\n]+)/);
  const unpackedMatch = packOutput.match(/unpacked size: ([^\n]+)/);
  const filesMatch = packOutput.match(/total files: (\d+)/);
  
  if (sizeMatch && unpackedMatch && filesMatch) {
    log(`Package size: ${sizeMatch[1]}`, colors.cyan);
    log(`Unpacked size: ${unpackedMatch[1]}`, colors.cyan);
    log(`Total files: ${filesMatch[1]}`, colors.cyan);
  }

  // Verify critical files are included
  const requiredFiles = [
    'peekaboo',
    'peekaboo-mcp.js',
    'README.md',
    'LICENSE'
  ];

  let allFilesPresent = true;
  for (const file of requiredFiles) {
    if (!packOutput.includes(file)) {
      logError(`Missing required file in package: ${file}`);
      allFilesPresent = false;
    }
  }

  if (!allFilesPresent) {
    return false;
  }
  logSuccess('All required files included in package');

  // Verify peekaboo binary
  log('Verifying peekaboo binary...', colors.cyan);
  const binaryPath = binaryOverride ?? join(projectRoot, 'peekaboo');
  
  // Check if binary exists
  if (!existsSync(binaryPath)) {
    logError('peekaboo binary not found');
    return false;
  }
  
  // Check if binary is executable
  try {
    const stats = exec(`stat -f "%Lp" "${binaryPath}" 2>/dev/null || stat -c "%a" "${binaryPath}"`);
    const perms = parseInt(stats, 8);
    if ((perms & 0o111) === 0) {
      logError('peekaboo binary is not executable');
      return false;
    }
  } catch (error) {
    logError('Failed to check binary permissions');
    return false;
  }
  
  // Check binary architectures (arm64 required; x86_64 optional unless explicitly enforced)
  try {
    const lipoOutput = exec(`lipo -info "${binaryPath}"`);
    const hasArm64 = lipoOutput.includes('arm64');
    const hasX86 = lipoOutput.includes('x86_64');
    if (!hasArm64) {
      logError('peekaboo binary is missing arm64');
      logError(`Found: ${lipoOutput}`);
      return false;
    }
    if (process.env.PEEKABOO_REQUIRE_UNIVERSAL === '1' && !hasX86) {
      logError('peekaboo binary does not contain x86_64 (PEEKABOO_REQUIRE_UNIVERSAL=1)');
      logError(`Found: ${lipoOutput}`);
      return false;
    }
    if (hasX86) {
      logSuccess('Binary contains both arm64 and x86_64 architectures');
    } else {
      logWarning('Binary is arm64-only (set PEEKABOO_REQUIRE_UNIVERSAL=1 to enforce universal)');
    }
  } catch (error) {
    logError('Failed to check binary architectures (lipo command failed)');
    return false;
  }
  
  // Check if binary responds to --help
  try {
    const helpOutput = exec(`"${binaryPath}" --help`);
    if (!helpOutput || helpOutput.length === 0) {
      logError('peekaboo binary does not respond to --help command');
      return false;
    }
    logSuccess('Binary responds correctly to --help command');
  } catch (error) {
    logError('peekaboo binary failed to execute with --help');
    logError(`Error: ${error.message}`);
    return false;
  }
  
  logSuccess('peekaboo binary verification passed');

  // Check package.json version
  const packageJson = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
  const version = packageJson.version;
  
  if (!version.match(/^\d+\.\d+\.\d+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$/)) {
    logError(`Invalid version format: ${version}`);
    return false;
  }
  log(`Package version: ${version}`, colors.cyan);

  return true;
}

// Main execution
async function main() {
  console.log(`\n${colors.bright}🚀 Peekaboo Release Preparation${colors.reset}\n`);

  if (dryRun) {
    const debugBinary = join(projectRoot, 'Apps', 'CLI', '.build', 'debug', 'peekaboo');
    const packagedBinary = join(projectRoot, 'peekaboo');
    const binaryPath = binaryOverride ?? (existsSync(debugBinary) ? debugBinary : packagedBinary);
    const checks = [
      checkRequiredFields,
      checkVersionConsistency,
      checkChangelog,
      checkDocs,
      () => checkSwiftCLIIntegration(binaryPath)
    ];

    for (const check of checks) {
      if (!check()) {
        console.log(`\n${colors.red}${colors.bright}❌ Release dry-run checks failed!${colors.reset}\n`);
        process.exit(1);
      }
    }

    console.log(`\n${colors.green}${colors.bright}✅ Deterministic release dry-run checks passed.${colors.reset}`);
    console.log(`${colors.yellow}This mode does not prove git cleanliness, registry availability, tests, or release artifacts.${colors.reset}\n`);
    return;
  }

  const checks = [
    checkGitStatus,
    checkRequiredFields,
    checkDependencies,
    checkVersionAvailability,
    checkVersionConsistency,
    checkChangelog,
    checkDocs,
    checkSwift,
    buildAndVerifyPackage,
    () => checkSwiftCLIIntegration(binaryOverride ?? join(projectRoot, 'peekaboo')),
    checkPackageSize
  ];

  for (const check of checks) {
    if (!check()) {
      console.log(`\n${colors.red}${colors.bright}❌ Release preparation failed!${colors.reset}\n`);
      process.exit(1);
    }
  }

  console.log(`\n${colors.green}${colors.bright}✅ All checks passed! Ready for the release workflow. 🎉${colors.reset}\n`);
  console.log(`Follow docs/RELEASING.md and run scripts/release-binaries.sh with the intended publish flags.`);
  console.log(`This preflight does not tag, publish, notarize, or create a GitHub release.\n`);
}

// Run the script
main().catch(error => {
  logError(`Unexpected error: ${error.message}`);
  process.exit(1);
});
