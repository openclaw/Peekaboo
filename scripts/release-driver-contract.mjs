#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

function fail(message) {
  throw new Error(message);
}

export function canonicalReleasePlan({
  sourceCommit, version, helperCommit, helperExecutableSHA256, helperLibrarySHA256, proofSHA256 = null,
  preflightCompleted = false, publicationEligible = false,
}) {
  if (!/^[0-9a-f]{40}$/.test(sourceCommit ?? '')) fail('release source commit is invalid');
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?$/.test(version ?? '')) {
    fail('release version is invalid');
  }
  if (!/^[0-9a-f]{40}$/.test(helperCommit ?? '')) fail('release helper commit is invalid');
  if (!/^[0-9a-f]{64}$/.test(helperExecutableSHA256 ?? '') ||
      !/^[0-9a-f]{64}$/.test(helperLibrarySHA256 ?? '')) {
    fail('release helper hashes are invalid');
  }
  if (proofSHA256 !== null && !/^[0-9a-f]{64}$/.test(proofSHA256)) fail('release proof hash is invalid');
  if (typeof preflightCompleted !== 'boolean' || typeof publicationEligible !== 'boolean' ||
      (publicationEligible && (!preflightCompleted || proofSHA256 === null))) {
    fail('release publication eligibility is invalid');
  }
  return {
    helper: {
      commit: helperCommit,
      executable_sha256: helperExecutableSHA256,
      library_sha256: helperLibrarySHA256,
    },
    preflight_completed: preflightCompleted,
    proof_sha256: proofSHA256,
    publication_eligible: publicationEligible,
    schema_version: 2,
    source_commit: sourceCommit,
    version,
  };
}

export function validateCanonicalReleasePlan(plan) {
  if (!plan || typeof plan !== 'object' || Array.isArray(plan)) fail('release plan is invalid');
  const canonical = canonicalReleasePlan({
    sourceCommit: plan.source_commit,
    version: plan.version,
    helperCommit: plan.helper?.commit,
    helperExecutableSHA256: plan.helper?.executable_sha256,
    helperLibrarySHA256: plan.helper?.library_sha256,
    proofSHA256: plan.proof_sha256,
    preflightCompleted: plan.preflight_completed,
    publicationEligible: plan.publication_eligible,
  });
  if (JSON.stringify(plan) !== JSON.stringify(canonical)) fail('release plan is not canonical');
  return canonical;
}

export function canonicalPublicationReceipt({
  sourceCommit, version, checksumsSHA256, githubBodySHA256, assets,
}) {
  if (!/^[0-9a-f]{40}$/.test(sourceCommit ?? '')) fail('publication source commit is invalid');
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?$/.test(version ?? '')) {
    fail('publication version is invalid');
  }
  if (!/^[0-9a-f]{64}$/.test(checksumsSHA256 ?? '') ||
      !/^[0-9a-f]{64}$/.test(githubBodySHA256 ?? '')) {
    fail('publication receipt hashes are invalid');
  }
  if (!assets || typeof assets !== 'object' || Array.isArray(assets) || Object.keys(assets).length === 0) {
    fail('publication asset inventory is invalid');
  }
  const canonicalAssets = {};
  for (const name of Object.keys(assets).sort()) {
    const value = assets[name];
    if (name.length === 0 || name.includes('/') || !value || !Number.isSafeInteger(value.size) || value.size < 0 ||
        !/^[0-9a-f]{64}$/.test(value.sha256 ?? '')) {
      fail('publication asset receipt is invalid');
    }
    canonicalAssets[name] = { size: value.size, sha256: value.sha256 };
  }
  return {
    assets: canonicalAssets,
    checksums_sha256: checksumsSHA256,
    github_body_sha256: githubBodySHA256,
    schema_version: 1,
    source_commit: sourceCommit,
    version,
  };
}

export function validatePublicationOptions(options) {
  const resume = options?.resumePublication === true;
  const publicAction = options?.createGithubRelease === true || options?.publishNpm === true ||
    options?.retryNpmPublish === true || resume;
  if (!publicAction) {
    if (options?.proofProvided === true) fail('--proof-file requires a public release action');
    return;
  }
  const invalid = [];
  if (resume && (options.createGithubRelease === true || options.publishNpm === true)) {
    invalid.push('--resume-publication cannot be combined with create or publish flags');
  } else if (!resume && (options.createGithubRelease !== true || options.publishNpm !== true)) {
    invalid.push('--create-github-release and --publish-npm must be used together');
  }
  if (options.skipChecks === true) invalid.push('--skip-checks');
  if (options.universal !== true) invalid.push('--arm64-only');
  if (options.includeMacApp !== true) invalid.push('--skip-mac-app');
  if (options.notarize !== true) invalid.push('--no-notarize-mac-app');
  if (options.appcast !== true) invalid.push('--no-appcast');
  if (resume && options.proofProvided === true) invalid.push('--proof-file with --resume-publication');
  if (resume && options.reuseBuiltCLI === true) invalid.push('--reuse-built-cli with --resume-publication');
  if (!resume && options.retryNpmPublish === true) invalid.push('--retry-npm-publish requires --resume-publication');
  if (!resume && options.proofProvided !== true) invalid.push('--proof-file');
  if (invalid.length > 0) {
    fail(`public release refuses unsafe options: ${invalid.join(', ')}`);
  }
}

export function validateReleaseSourceState({
  expectedCommit, observedCommit, porcelain, expectedAppcastSHA256 = null, observedAppcastSHA256 = null,
}) {
  if (!/^[0-9a-f]{40}$/.test(expectedCommit ?? '') || observedCommit !== expectedCommit) {
    fail('release source commit differs from the frozen plan');
  }
  if (expectedAppcastSHA256 === null) {
    if (porcelain !== '') fail('release checkout changed before appcast generation');
    return;
  }
  if (!/^[0-9a-f]{64}$/.test(expectedAppcastSHA256) || observedAppcastSHA256 !== expectedAppcastSHA256) {
    fail('generated appcast differs from the frozen plan');
  }
  if (porcelain !== '' && porcelain !== ' M appcast.xml') {
    fail('release checkout has changes outside the generated appcast');
  }
}

export function validateAppZipMembers({ members, appRoot = 'Peekaboo.app' }) {
  if (!Array.isArray(members) || members.length === 0 ||
      typeof appRoot !== 'string' || !/^[^/\\]+\.app$/.test(appRoot)) {
    fail('app zip member inventory is invalid');
  }
  const seen = new Set();
  for (const raw of members) {
    if (typeof raw !== 'string' || raw.length === 0 || raw.includes('\0') || raw.includes('\\')) {
      fail('app zip contains an invalid member name');
    }
    const name = raw.endsWith('/') ? raw.slice(0, -1) : raw;
    const parts = name.split('/');
    if (parts[0] !== appRoot || parts.some((part) => part === '' || part === '.' || part === '..')) {
      fail('app zip contains a member outside the exact app root');
    }
    if (seen.has(name)) fail('app zip contains duplicate members');
    seen.add(name);
  }
}

function normalizedNotes(value) {
  if (typeof value !== 'string' || value.trim().length === 0) fail('release notes are empty');
  return `${value.replace(/\r\n?/g, '\n').replace(/\s+$/u, '')}\n`;
}

export function extractReleaseNotes(changelog, version) {
  if (typeof changelog !== 'string') fail('changelog is invalid');
  changelog = changelog.replace(/\r\n?/g, '\n');
  const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const heading = new RegExp(`^## \\[?${escaped}\\]?(?: - .+)?$`);
  const lines = changelog.split('\n');
  const start = lines.findIndex((line) => heading.test(line));
  if (start < 0) fail(`changelog has no release section for ${version}`);
  const relativeEnd = lines.slice(start + 1).findIndex((line) => line.startsWith('## '));
  const end = relativeEnd < 0 ? lines.length : start + 1 + relativeEnd;
  return normalizedNotes(lines.slice(start, end).join('\n'));
}

export function validateTrackedReleaseNotes({ changelog, notes, version }) {
  const expected = extractReleaseNotes(changelog, version);
  if (normalizedNotes(notes) !== expected) fail('tracked release notes differ from CHANGELOG.md');
  return expected;
}

export function npmIntegrity(bytes) {
  return `sha512-${createHash('sha512').update(bytes).digest('base64')}`;
}

export function validateNpmPublication({ metadata, packageName, version, localIntegrity }) {
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) fail('npm metadata is invalid');
  if (metadata.version !== version) fail('npm published version differs from release plan');
  if (metadata.dist?.integrity !== localIntegrity) fail('npm integrity differs from the local package');
  if (typeof metadata.time?.[version] !== 'string' || Number.isNaN(Date.parse(metadata.time[version]))) {
    fail('npm publish time is missing or invalid');
  }
  let tarball;
  try {
    tarball = new URL(metadata.dist?.tarball);
  } catch {
    fail('npm tarball URL is invalid');
  }
  if (tarball.protocol !== 'https:' || tarball.hostname !== 'registry.npmjs.org' ||
      !tarball.pathname.startsWith(`/${packageName}/-/`)) {
    fail('npm tarball URL differs from the expected package');
  }
}

export function classifyNpmViewResult({ exitCode, stdout, stderr, expectedVersion }) {
  if (!Number.isInteger(exitCode) || typeof stdout !== 'string' || typeof stderr !== 'string') {
    fail('npm view result is invalid');
  }
  if (exitCode === 0) {
    let observed;
    try {
      observed = JSON.parse(stdout);
    } catch {
      fail('npm returned invalid publication metadata');
    }
    if (observed !== expectedVersion) fail('npm returned an unexpected published version');
    return 'published';
  }
  if (/E404|404 Not Found/.test(`${stdout}\n${stderr}`)) return 'absent';
  fail(`npm publication state probe failed with exit ${exitCode}`);
}

export function validateNpmPublishAttempt({ marker, sourceCommit, version, npmIntegrity: integrity }) {
  const expected = { source_commit: sourceCommit, version, npm_integrity: integrity };
  if (!marker || JSON.stringify(marker) !== JSON.stringify(expected) ||
      !/^[0-9a-f]{40}$/.test(sourceCommit ?? '') || !/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(integrity ?? '')) {
    fail('npm publish-attempt marker differs from retained artifacts');
  }
}

export function composeGitHubBody({ notes, proof, plan, checksumsSHA256, npm = null }) {
  const normalized = normalizedNotes(notes).trimEnd();
  const normalizedProof = normalizedNotes(proof).trimEnd();
  const canonicalPlan = canonicalReleasePlan({
    sourceCommit: plan.source_commit,
    version: plan.version,
    helperCommit: plan.helper?.commit,
    helperExecutableSHA256: plan.helper?.executable_sha256,
    helperLibrarySHA256: plan.helper?.library_sha256,
    proofSHA256: plan.proof_sha256,
    preflightCompleted: plan.preflight_completed,
    publicationEligible: plan.publication_eligible,
  });
  if (!canonicalPlan.preflight_completed || !canonicalPlan.publication_eligible) {
    fail('release plan is not eligible for publication');
  }
  if (createHash('sha256').update(proof).digest('hex') !== canonicalPlan.proof_sha256) {
    fail('release proof differs from the release plan');
  }
  if (!/^[0-9a-f]{64}$/.test(checksumsSHA256 ?? '')) fail('checksums hash is invalid');
  const lines = [
    normalized,
    '',
    '## Verification',
    '',
    `- Source commit: \`${canonicalPlan.source_commit}\``,
    `- Release plan SHA-256: \`${createHash('sha256').update(`${JSON.stringify(canonicalPlan)}\n`).digest('hex')}\``,
    `- Checksums SHA-256: \`${checksumsSHA256}\``,
  ];
  if (npm === null) {
    lines.push('- npm publication: pending');
  } else {
    lines.push(
      `- npm version: \`${npm.version}\``,
      `- npm tarball: ${npm.dist.tarball}`,
      `- npm integrity: \`${npm.dist.integrity}\``,
      `- npm published: \`${npm.time[npm.version]}\``,
    );
  }
  lines.push('', '### Proof', '', normalizedProof, '');
  return lines.join('\n');
}

export function validateGitHubRelease({
  release, version, sourceCommit, tagCommit, expectedAssets, expectedBody, expectDraft,
  allowAssetRepair = false,
}) {
  if (!release || typeof release !== 'object' || Array.isArray(release)) fail('GitHub release is invalid');
  if (!/^[0-9a-f]{40}$/.test(sourceCommit ?? '') || tagCommit !== sourceCommit) {
    fail('GitHub release tag differs from the frozen source commit');
  }
  const tagName = release.tagName ?? release.tag_name;
  const isDraft = release.isDraft ?? release.draft;
  if (tagName !== `v${version}`) fail('GitHub release tag differs from the release plan');
  if (isDraft !== expectDraft) fail('GitHub release draft state is unexpected');
  if (expectedBody !== null && normalizedNotes(release.body) !== normalizedNotes(expectedBody)) {
    fail('GitHub release body differs from tracked release notes');
  }
  const assets = Array.isArray(release.assets) ? release.assets : [];
  const expectedNames = Object.keys(expectedAssets ?? {}).sort();
  const observedNames = assets.map((asset) => asset?.name).sort();
  if (allowAssetRepair) {
    if (new Set(observedNames).size !== observedNames.length ||
        observedNames.some((name) => !Object.hasOwn(expectedAssets, name))) {
      fail('GitHub release contains an unexpected asset that cannot be repaired');
    }
    return;
  }
  if (JSON.stringify(observedNames) !== JSON.stringify(expectedNames)) {
    fail('GitHub release asset inventory differs from the local release');
  }
  for (const [name, expected] of Object.entries(expectedAssets ?? {})) {
    const matches = assets.filter((asset) => asset?.name === name);
    if (matches.length !== 1) fail(`GitHub release asset count differs for ${name}`);
    if (matches[0].size !== expected.size) fail(`GitHub release asset size differs for ${name}`);
    if (matches[0].digest !== `sha256:${expected.sha256}`) {
      fail(`GitHub release asset digest differs for ${name}`);
    }
  }
}

function readInput() {
  const raw = fs.readFileSync(0, 'utf8');
  return JSON.parse(raw);
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  try {
    const command = process.argv[2];
    const input = readInput();
    switch (command) {
      case 'publication-options':
        validatePublicationOptions(input);
        break;
      case 'release-plan':
        process.stdout.write(`${JSON.stringify(canonicalReleasePlan(input))}\n`);
        break;
      case 'release-plan-file':
        process.stdout.write(`${JSON.stringify(validateCanonicalReleasePlan(input))}\n`);
        break;
      case 'publication-receipt':
        process.stdout.write(`${JSON.stringify(canonicalPublicationReceipt(input))}\n`);
        break;
      case 'source-state':
        validateReleaseSourceState(input);
        break;
      case 'app-zip-members':
        validateAppZipMembers(input);
        break;
      case 'tracked-notes':
        process.stdout.write(validateTrackedReleaseNotes(input));
        break;
      case 'npm-publication':
        validateNpmPublication(input);
        break;
      case 'npm-view-state':
        process.stdout.write(`${classifyNpmViewResult(input)}\n`);
        break;
      case 'npm-publish-attempt':
        validateNpmPublishAttempt(input);
        break;
      case 'github-body':
        process.stdout.write(composeGitHubBody(input));
        break;
      case 'github-release':
        validateGitHubRelease(input);
        break;
      default:
        fail('unknown release-driver contract command');
    }
  } catch (error) {
    process.stderr.write(`release-driver-contract: ${error.message}\n`);
    process.exitCode = 1;
  }
}
