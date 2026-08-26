#!/usr/bin/env node

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import {
  canonicalReleasePlan,
  canonicalPublicationReceipt,
  classifyNpmViewResult,
  composeGitHubBody,
  extractReleaseNotes,
  npmIntegrity,
  validateAppZipMembers,
  validateGitHubRelease,
  validateNpmPublication,
  validateNpmPublishAttempt,
  validatePublicationOptions,
  validateCanonicalReleasePlan,
  validateReleaseSourceState,
  validateTrackedReleaseNotes,
} from './release-driver-contract.mjs';

const sourceCommit = 'a'.repeat(40);
const helperCommit = 'b'.repeat(40);
const helperExecutableSHA256 = 'c'.repeat(64);
const helperLibrarySHA256 = 'd'.repeat(64);
const planInput = {
  sourceCommit, version: '9.8.7', helperCommit, helperExecutableSHA256, helperLibrarySHA256,
  preflightCompleted: true, publicationEligible: false,
};
const publicationAssets = {
  'release-plan.json': { size: 84, sha256: 'e'.repeat(64) },
  'checksums.txt': { size: 42, sha256: 'f'.repeat(64) },
};
const publicationReceipt = canonicalPublicationReceipt({
  sourceCommit,
  version: '9.8.7',
  checksumsSHA256: '1'.repeat(64),
  githubBodySHA256: '2'.repeat(64),
  assets: publicationAssets,
});
assert.deepEqual(Object.keys(publicationReceipt.assets), ['checksums.txt', 'release-plan.json']);
assert.throws(() => canonicalPublicationReceipt({
  sourceCommit,
  version: '9.8.7',
  checksumsSHA256: '1'.repeat(64),
  githubBodySHA256: '2'.repeat(64),
  assets: { ...publicationAssets, 'checksums.txt': { size: 43, sha256: 'wrong' } },
}), /asset receipt/);
assert.deepEqual(canonicalReleasePlan(planInput), {
  helper: {
    commit: helperCommit,
    executable_sha256: helperExecutableSHA256,
    library_sha256: helperLibrarySHA256,
  },
  preflight_completed: true,
  publication_eligible: false,
  schema_version: 2,
  source_commit: sourceCommit,
  proof_sha256: null,
  version: '9.8.7',
});
assert.deepEqual(validateCanonicalReleasePlan(canonicalReleasePlan(planInput)),
  canonicalReleasePlan(planInput));
assert.throws(() => validateCanonicalReleasePlan({
  ...canonicalReleasePlan(planInput), extra: true,
}), /not canonical/);
assert.throws(() => canonicalReleasePlan({
  ...planInput, preflightCompleted: false, publicationEligible: true,
}), /eligibility/);
for (const value of ['', 'a'.repeat(39), 'A'.repeat(40)]) {
  assert.throws(() => canonicalReleasePlan({ ...planInput, sourceCommit: value }));
}
assert.doesNotThrow(() => validateReleaseSourceState({
  expectedCommit: sourceCommit, observedCommit: sourceCommit, porcelain: '',
}));
const appcastSHA256 = '9'.repeat(64);
assert.doesNotThrow(() => validateReleaseSourceState({
  expectedCommit: sourceCommit,
  observedCommit: sourceCommit,
  porcelain: '',
  expectedAppcastSHA256: appcastSHA256,
  observedAppcastSHA256: appcastSHA256,
}));
assert.doesNotThrow(() => validateReleaseSourceState({
  expectedCommit: sourceCommit,
  observedCommit: sourceCommit,
  porcelain: ' M appcast.xml',
  expectedAppcastSHA256: appcastSHA256,
  observedAppcastSHA256: appcastSHA256,
}));
for (const changed of [
  { expectedCommit: sourceCommit, observedCommit: helperCommit, porcelain: '' },
  { expectedCommit: sourceCommit, observedCommit: sourceCommit, porcelain: ' M CHANGELOG.md' },
  { expectedCommit: sourceCommit, observedCommit: sourceCommit, porcelain: 'M  appcast.xml',
    expectedAppcastSHA256: appcastSHA256, observedAppcastSHA256: appcastSHA256 },
  { expectedCommit: sourceCommit, observedCommit: sourceCommit, porcelain: ' M appcast.xml',
    expectedAppcastSHA256: appcastSHA256, observedAppcastSHA256: '8'.repeat(64) },
]) {
  assert.throws(() => validateReleaseSourceState(changed));
}

assert.doesNotThrow(() => validateAppZipMembers({
  members: ['Peekaboo.app/', 'Peekaboo.app/Contents/', 'Peekaboo.app/Contents/Info.plist'],
}));
for (const members of [
  ['Peekaboo.app/', 'README.txt'],
  ['Peekaboo.app/Contents/../../outside'],
  ['/Peekaboo.app/Contents/Info.plist'],
  ['Peekaboo.app/Contents/Info.plist', 'Peekaboo.app/Contents/Info.plist'],
  ['Peekaboo.app\\Contents\\Info.plist'],
]) {
  assert.throws(() => validateAppZipMembers({ members }));
}

const safeOptions = {
  appcast: true,
  createGithubRelease: true,
  includeMacApp: true,
  notarize: true,
  publishNpm: true,
  proofProvided: true,
  skipChecks: false,
  universal: true,
};
assert.doesNotThrow(() => validatePublicationOptions(safeOptions));
assert.doesNotThrow(() => validatePublicationOptions({ ...safeOptions,
  createGithubRelease: false, publishNpm: false, proofProvided: false, skipChecks: true }));
assert.throws(() => validatePublicationOptions({ ...safeOptions,
  createGithubRelease: false, publishNpm: false }), /--proof-file requires/);
assert.throws(() => validatePublicationOptions({ ...safeOptions, proofProvided: false }), /--proof-file/);
assert.throws(() => validatePublicationOptions({
  ...safeOptions, createGithubRelease: true, publishNpm: false,
}), /must be used together/);
assert.throws(() => validatePublicationOptions({
  ...safeOptions, createGithubRelease: false, publishNpm: true,
}), /must be used together/);
assert.doesNotThrow(() => validatePublicationOptions({
  ...safeOptions, createGithubRelease: false, publishNpm: false,
  proofProvided: false, resumePublication: true,
}));
assert.throws(() => validatePublicationOptions({
  ...safeOptions, resumePublication: true,
}), /cannot be combined/);
assert.throws(() => validatePublicationOptions({
  ...safeOptions, createGithubRelease: false, publishNpm: false,
  resumePublication: true, reuseBuiltCLI: true,
}), /--reuse-built-cli/);
assert.throws(() => validatePublicationOptions({
  ...safeOptions, retryNpmPublish: true,
}), /requires --resume-publication/);
assert.throws(() => validatePublicationOptions({
  ...safeOptions, createGithubRelease: false, publishNpm: false,
  proofProvided: false, retryNpmPublish: true,
}), /requires --resume-publication/);
for (const publicAction of ['createGithubRelease', 'publishNpm']) {
  assert.throws(() => validatePublicationOptions({
    ...safeOptions,
    createGithubRelease: publicAction === 'createGithubRelease',
    publishNpm: publicAction === 'publishNpm',
    proofProvided: false,
  }), /--proof-file/);
}
for (const publicAction of ['createGithubRelease', 'publishNpm']) {
  for (const [key, value] of [
    ['skipChecks', true],
    ['universal', false],
    ['includeMacApp', false],
    ['notarize', false],
    ['appcast', false],
  ]) {
    assert.throws(() => validatePublicationOptions({
      ...safeOptions,
      createGithubRelease: publicAction === 'createGithubRelease',
      publishNpm: publicAction === 'publishNpm',
      [key]: value,
    }), /unsafe options/);
  }
}

const changelog = `# Changelog

## [9.8.7] - 2026-08-26

### Fixed
- Bound every artifact.

## [9.8.6] - 2026-08-25
- Older.
`;
const notes = `## [9.8.7] - 2026-08-26

### Fixed
- Bound every artifact.
`;
assert.equal(extractReleaseNotes(changelog, '9.8.7'), notes);
assert.equal(validateTrackedReleaseNotes({ changelog, notes, version: '9.8.7' }), notes);
assert.equal(validateTrackedReleaseNotes({
  changelog: changelog.replaceAll('\n', '\r\n'), notes, version: '9.8.7',
}), notes);
assert.throws(() => validateTrackedReleaseNotes({ changelog, notes: `${notes}- drift\n`, version: '9.8.7' }),
  /differ/);

const packageBytes = Buffer.from('deterministic npm package');
const localIntegrity = npmIntegrity(packageBytes);
const npmMetadata = {
  version: '9.8.7',
  time: { '9.8.7': '2026-08-26T12:00:00.000Z' },
  dist: {
    integrity: localIntegrity,
    tarball: 'https://registry.npmjs.org/@steipete/peekaboo/-/peekaboo-9.8.7.tgz',
  },
};
assert.doesNotThrow(() => validateNpmPublication({
  metadata: npmMetadata,
  packageName: '@steipete/peekaboo',
  version: '9.8.7',
  localIntegrity,
}));
for (const changed of [
  { ...npmMetadata, version: '9.8.6' },
  { ...npmMetadata, dist: { ...npmMetadata.dist, integrity: 'sha512-wrong' } },
  { ...npmMetadata, dist: { ...npmMetadata.dist, tarball: 'https://example.com/peekaboo.tgz' } },
  { ...npmMetadata, time: {} },
]) {
  assert.throws(() => validateNpmPublication({
    metadata: changed,
    packageName: '@steipete/peekaboo',
    version: '9.8.7',
    localIntegrity,
  }));
}
assert.equal(classifyNpmViewResult({
  exitCode: 0, stdout: '"9.8.7"', stderr: '', expectedVersion: '9.8.7',
}), 'published');
assert.equal(classifyNpmViewResult({
  exitCode: 1, stdout: '', stderr: 'npm error code E404', expectedVersion: '9.8.7',
}), 'absent');
for (const probe of [
  { exitCode: 0, stdout: 'null', stderr: '' },
  { exitCode: 0, stdout: 'not-json', stderr: '' },
  { exitCode: 1, stdout: '', stderr: 'npm error code E500' },
]) {
  assert.throws(() => classifyNpmViewResult({ ...probe, expectedVersion: '9.8.7' }));
}
const npmAttempt = {
  source_commit: sourceCommit,
  version: '9.8.7',
  npm_integrity: localIntegrity,
};
assert.doesNotThrow(() => validateNpmPublishAttempt({
  marker: npmAttempt, sourceCommit, version: '9.8.7', npmIntegrity: localIntegrity,
}));
assert.throws(() => validateNpmPublishAttempt({
  marker: { ...npmAttempt, version: '9.8.6' },
  sourceCommit, version: '9.8.7', npmIntegrity: localIntegrity,
}), /differs/);

const proof = 'Hosted CI run 123 and focused release tests passed.\n';
const bodyPlan = canonicalReleasePlan({
  ...planInput,
  proofSHA256: createHash('sha256').update(proof).digest('hex'),
  publicationEligible: true,
});
const pendingBody = composeGitHubBody({
  notes, proof, plan: bodyPlan, checksumsSHA256: 'f'.repeat(64),
});
assert.ok(pendingBody.startsWith(notes.trimEnd()));
assert.match(pendingBody, /npm publication: pending/);
assert.match(pendingBody, /### Proof\n\nHosted CI run 123/);
assert.throws(() => composeGitHubBody({
  notes, proof: `${proof}drift\n`, plan: bodyPlan, checksumsSHA256: 'f'.repeat(64),
}), /proof differs/);
const publishedBody = composeGitHubBody({
  notes, proof, plan: bodyPlan, checksumsSHA256: 'f'.repeat(64), npm: npmMetadata,
});
assert.match(publishedBody, /npm integrity:/);
assert.match(publishedBody, /2026-08-26T12:00:00.000Z/);
const foreignRun = spawnSync(process.execPath, [
  fileURLToPath(new URL('./release-driver-contract.mjs', import.meta.url)), 'github-body',
], {
  cwd: '/private/tmp',
  encoding: 'utf8',
  input: JSON.stringify({ notes, proof, plan: bodyPlan, checksumsSHA256: 'f'.repeat(64), npm: npmMetadata }),
});
assert.equal(foreignRun.status, 0, foreignRun.stderr);
assert.equal(foreignRun.stdout, publishedBody);

const expectedAssets = {
  'checksums.txt': { size: 42, sha256: 'c'.repeat(64) },
  'release-plan.json': { size: 84, sha256: 'd'.repeat(64) },
};
const release = {
  tagName: 'v9.8.7',
  isDraft: true,
  body: notes,
  assets: Object.entries(expectedAssets).map(([name, value]) => ({
    digest: `sha256:${value.sha256}`,
    name,
    size: value.size,
  })),
};
assert.doesNotThrow(() => validateGitHubRelease({
  release, version: '9.8.7', sourceCommit, tagCommit: sourceCommit,
  expectedAssets, expectedBody: notes, expectDraft: true,
}));
assert.doesNotThrow(() => validateGitHubRelease({
  release: { ...release, body: 'resume will replace this body' },
  version: '9.8.7', sourceCommit, tagCommit: sourceCommit,
  expectedAssets, expectedBody: null, expectDraft: true,
}));
assert.doesNotThrow(() => validateGitHubRelease({
  release: { ...release, body: 'resume', assets: release.assets.slice(0, 1) },
  version: '9.8.7', sourceCommit, tagCommit: sourceCommit,
  expectedAssets, expectedBody: null, expectDraft: true, allowAssetRepair: true,
}));
assert.throws(() => validateGitHubRelease({
  release: { ...release, assets: [...release.assets, { name: 'foreign', size: 1, digest: 'sha256:bad' }] },
  version: '9.8.7', sourceCommit, tagCommit: sourceCommit,
  expectedAssets, expectedBody: null, expectDraft: true, allowAssetRepair: true,
}), /unexpected asset/);
assert.doesNotThrow(() => validateGitHubRelease({
  release: { ...release, body: publishedBody },
  version: '9.8.7', sourceCommit, tagCommit: sourceCommit,
  expectedAssets, expectedBody: publishedBody, expectDraft: true,
}));
assert.doesNotThrow(() => validateGitHubRelease({
  release: { ...release, tag_name: release.tagName, draft: release.isDraft, tagName: undefined, isDraft: undefined },
  version: '9.8.7', sourceCommit, tagCommit: sourceCommit,
  expectedAssets, expectedBody: notes, expectDraft: true,
}));
assert.throws(() => validateGitHubRelease({
  release, version: '9.8.7', sourceCommit, tagCommit: helperCommit,
  expectedAssets, expectedBody: notes, expectDraft: true,
}), /tag differs from the frozen source commit/);
for (const changed of [
  { ...release, isDraft: false },
  { ...release, body: `${notes}drift\n` },
  { ...release, assets: release.assets.map((asset, index) => index === 0 ? { ...asset, size: 43 } : asset) },
  { ...release, assets: release.assets.map((asset, index) => index === 0 ?
    { ...asset, digest: `sha256:${'e'.repeat(64)}` } : asset) },
  { ...release, assets: [...release.assets, { name: 'extra', size: 1, digest: `sha256:${'f'.repeat(64)}` }] },
]) {
  assert.throws(() => validateGitHubRelease({
    release: changed, version: '9.8.7', sourceCommit, tagCommit: sourceCommit,
    expectedAssets, expectedBody: notes, expectDraft: true,
  }));
}

console.log('test-release-driver-contract: ok');
