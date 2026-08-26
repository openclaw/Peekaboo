#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { lstat, mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

function canonicalValue(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return value;
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || Object.is(value, -0) ||
        (Number.isInteger(value) && !Number.isSafeInteger(value))) throw new TypeError('invalid canonical number');
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new TypeError('invalid canonical value');
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
}

function aggregateSHA256(name, value) {
  return createHash('sha256').update(Buffer.concat([
    Buffer.from(`peekaboo.multi-target-certification.${name}.v2\0`, 'utf8'),
    Buffer.from(JSON.stringify(canonicalValue(value)), 'utf8')
  ])).digest('hex');
}

const manifestArgument = process.argv[2];
if (!manifestArgument || process.argv.length !== 3) {
  console.error('Usage: scripts/validate-terminal-artifact-manifest.mjs MANIFEST');
  process.exit(2);
}
const manifestPath = path.resolve(manifestArgument);
const root = path.dirname(manifestPath);
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
await requireDirectory(root, 'artifact root');
await requireRegularFile(manifestPath, 'terminal artifact manifest');
if (run('/usr/bin/xattr', ['-r', root]).trim()) throw new Error('artifact root contains unbound xattrs');
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const exactSHA = /^[0-9a-f]{64}$/;
const exactCDHash = /^[0-9a-f]{40,64}$/;
const exactSource = /^[0-9a-f]{40}$/;
const fixtureTools = process.env.PEEKABOO_TERMINAL_VALIDATOR_FIXTURE_TOOLS ?? null;
if (fixtureTools && (process.env.PEEKABOO_TERMINAL_TEST_MODE !== '1' || !path.isAbsolute(fixtureTools) ||
    path.resolve(fixtureTools) !== fixtureTools)) {
  throw new Error('validator fixture tools require explicit test mode and an absolute normalized path');
}
if (!fixtureTools && process.env.PEEKABOO_TERMINAL_TEST_MODE) {
  throw new Error('validator test mode requires fixture tools');
}
const codesignBinary = fixtureTools ? path.join(fixtureTools, 'codesign') : '/usr/bin/codesign';
if (fixtureTools) {
  await requireDirectory(fixtureTools, 'validator fixture tools');
  await requireRegularFile(codesignBinary, 'validator fixture codesign');
}

function exactKeys(value, expected, label) {
  const keys = value && typeof value === 'object' && !Array.isArray(value) ? Object.keys(value).sort() : [];
  const wanted = [...expected].sort();
  if (JSON.stringify(keys) !== JSON.stringify(wanted)) throw new Error(`${label} keys differ`);
}

function requireSafeRelativePath(candidate, label) {
  if (typeof candidate !== 'string' || !/^[A-Za-z0-9_./+-]+$/.test(candidate) ||
      candidate.startsWith('/') || candidate.includes('\\') || path.posix.normalize(candidate) !== candidate ||
      candidate.split('/').some((part) => !part || part === '.' || part === '..')) {
    throw new Error(`${label} is not a safe normalized relative path`);
  }
  return candidate;
}

async function sha256(filePath) {
  return createHash('sha256').update(await readFile(filePath)).digest('hex');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  if (result.status !== 0) throw new Error(`${path.basename(command)} failed: ${result.stderr || result.stdout}`);
  return result.stdout;
}

function signatureField(details, field) {
  const prefix = `${field}=`;
  return details.split('\n').find((line) => line.startsWith(prefix))?.slice(prefix.length) ?? '';
}

async function requireRegularFile(filePath, label) {
  const metadata = await lstat(filePath);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.nlink !== 1) {
    throw new Error(`${label} is not one regular unsymlinked file`);
  }
  return metadata;
}

async function requireDirectory(directoryPath, label) {
  const metadata = await lstat(directoryPath);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new Error(`${label} is not an unsymlinked directory`);
  }
  return metadata;
}

function inspectSignature(target, { deep = false, identifier, architecture = null } = {}) {
  const verifyArguments = ['--verify'];
  if (deep) verifyArguments.push('--deep');
  verifyArguments.push('--strict');
  if (architecture) verifyArguments.push('--arch', architecture);
  run(codesignBinary, [...verifyArguments,
    '-R=anchor apple generic and certificate leaf[subject.OU] = "FWJYW4S8P8"', target]);
  run(codesignBinary, [...verifyArguments, '--check-notarization', '-R=notarized', target]);
  const displayArguments = ['-dvvv'];
  if (architecture) displayArguments.push('--arch', architecture);
  displayArguments.push(target);
  const result = spawnSync(codesignBinary, displayArguments, { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`signature inspection failed: ${target}`);
  const details = `${result.stdout}${result.stderr}`;
  if (signatureField(details, 'Authority') !==
        'Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)' ||
      signatureField(details, 'TeamIdentifier') !== 'FWJYW4S8P8' ||
      (identifier && signatureField(details, 'Identifier') !== identifier)) {
    throw new Error(`signed identity mismatch: ${target}`);
  }
  return details;
}

function plistValue(plistPath, key) {
  return run('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', plistPath]).trim();
}

async function machoPlistValue(binary, key) {
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'peekaboo-macho-info-'));
  try {
    const architectures = run('/usr/bin/lipo', ['-archs', binary]).trim().split(/\s+/);
    if (architectures.length === 0 || !architectures[0]) throw new Error(`Mach-O has no architecture: ${binary}`);
    let expected = null;
    for (const architecture of architectures) {
      const thin = path.join(temporary, `thin-${architecture}`);
      run('/usr/bin/lipo', ['-thin', architecture, binary, '-output', thin]);
      const commands = run('/usr/bin/otool', ['-l', thin]).split('\n');
      let wanted = false;
      let segment = null;
      let size = null;
      let sectionSize = null;
      let sectionOffset = null;
      let matches = 0;
      for (const line of commands) {
        const fields = line.trim().split(/\s+/);
        if (fields[0] === 'sectname') {
          wanted = fields[1] === '__info_plist';
          segment = null;
          size = null;
        } else if (wanted && fields[0] === 'segname') segment = fields[1];
        else if (wanted && segment === '__TEXT' && fields[0] === 'size') size = Number.parseInt(fields[1], 16);
        else if (wanted && segment === '__TEXT' && fields[0] === 'offset') {
          sectionSize = size;
          sectionOffset = Number.parseInt(fields[1], 10);
          matches += 1;
          wanted = false;
        }
      }
      if (matches !== 1 || !Number.isSafeInteger(sectionSize) || sectionSize <= 0 ||
          !Number.isSafeInteger(sectionOffset) || sectionOffset < 0) {
        throw new Error(`Mach-O ${architecture} must have exactly one __TEXT,__info_plist: ${binary}`);
      }
      const bytes = await readFile(thin);
      if (sectionOffset + sectionSize > bytes.length) throw new Error(`Mach-O Info.plist exceeds file: ${binary}`);
      const result = spawnSync('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', '-'], {
        encoding: 'utf8', input: bytes.subarray(sectionOffset, sectionOffset + sectionSize)
      });
      if (result.status !== 0) throw new Error(`Mach-O Info.plist key missing: ${key}`);
      const value = result.stdout.trim();
      if (expected === null) expected = value;
      else if (value !== expected) throw new Error(`Mach-O Info.plist differs for ${architecture}: ${key}`);
    }
    return expected;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

async function extractAndCompare(record, kind, expectedRoot, expectedIdentifier) {
  const archive = path.join(root, record.path);
  const retainedTree = path.join(root, record.tree_manifest.path);
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'peekaboo-terminal-validate-'));
  try {
    if (kind === 'zip') {
      await archivePolicy.validateZipArchive(archive, expectedRoot, record.path);
      run('/usr/bin/ditto', ['-x', '-k', archive, temporary]);
    } else {
      await archivePolicy.validateTarGzArchive(archive, expectedRoot, record.path, { allowSymlinks: false });
      run('/usr/bin/tar', ['-xzf', archive, '-C', temporary]);
    }
    const extractedEntries = (await readdir(temporary)).sort();
    if (JSON.stringify(extractedEntries) !== JSON.stringify([expectedRoot])) {
      throw new Error(`${record.path} extracted unexpected roots`);
    }
    const extractedRoot = path.join(temporary, expectedRoot);
    if (run('/usr/bin/xattr', ['-r', extractedRoot]).trim()) throw new Error(`${record.path} contains xattrs`);
    const generated = run('/usr/bin/ruby', [trustedTreeGenerator, extractedRoot]);
    const retained = await readFile(retainedTree, 'utf8');
    if (generated !== retained) throw new Error(`${record.path} does not roundtrip to its tree receipt`);
    const retainedInventory = JSON.parse(retained);
    const signedTarget = kind === 'tar' ? path.join(extractedRoot, 'peekaboo') : extractedRoot;
    const signatureText = inspectSignature(signedTarget, {
      deep: kind === 'zip',
      identifier: expectedIdentifier,
      architecture: 'arm64'
    });
    if (signatureField(signatureText, 'CDHash') !== record.cdhash) {
      throw new Error(`${record.path} extracted code identity mismatch`);
    }
    if (kind === 'tar') {
      for (const architecture of ['arm64', 'x86_64']) {
        const details = inspectSignature(signedTarget, { identifier: expectedIdentifier, architecture });
        if (signatureField(details, 'CDHash') !== record.cdhashes[architecture]) {
          throw new Error(`CLI ${architecture} CDHash mismatch`);
        }
      }
      if (await machoPlistValue(signedTarget, 'PeekabooSourceCommit') !== manifest.source_commit ||
          await machoPlistValue(signedTarget, 'CFBundleShortVersionString') !== manifest.version ||
          await machoPlistValue(signedTarget, 'PeekabooCertificationSourceManifestSHA256') !==
            controllerSourceReceipt.aggregate_sha256 ||
          await machoPlistValue(signedTarget, 'PeekabooCertificationCatalogSHA256') !==
            controllerSourceReceipt.catalog_sha256) {
        throw new Error('CLI signed source/version mismatch');
      }
      for (const entry of retainedInventory.entries) {
        if (entry.path === '.' && entry.type === 'directory') continue;
        if (entry.type !== 'file' || entry.path.includes('/')) {
          throw new Error(`CLI archive contains a non-flat or non-file entry: ${entry.path}`);
        }
        if (entry.path === 'peekaboo' || entry.path === 'LICENSE' || entry.path === 'VERSION') continue;
        if (!/^libswiftCompatibility[^/]*\.dylib$/.test(entry.path)) {
          throw new Error(`CLI archive contains an unexpected file: ${entry.path}`);
        }
        const details = inspectSignature(path.join(extractedRoot, entry.path));
        if (!signatureField(details, 'Identifier').startsWith('com.apple.dt.runtime.swiftCompatibility')) {
          throw new Error(`CLI runtime identifier mismatch: ${entry.path}`);
        }
      }
      if ((await readFile(path.join(extractedRoot, 'VERSION'), 'utf8')).trim() !== manifest.version) {
        throw new Error('CLI VERSION file mismatch');
      }
      const notarizedTree = JSON.parse(await readFile(path.join(root, record.notarized_tree_manifest.path), 'utf8'));
      const signedEntries = retainedInventory.entries.filter((entry) =>
        entry.path === 'peekaboo' || /^libswiftCompatibility[^/]*\.dylib$/.test(entry.path));
      const notarizedEntries = notarizedTree.entries.filter((entry) => entry.path !== '.');
      if (JSON.stringify(signedEntries) !== JSON.stringify(notarizedEntries)) {
        throw new Error('CLI archive signed payload differs from notarized tree');
      }
    } else if (expectedRoot === 'Peekaboo.app') {
      const info = path.join(extractedRoot, 'Contents', 'Info.plist');
      if (plistValue(info, 'PeekabooSourceCommit') !== manifest.source_commit ||
          plistValue(info, 'CFBundleShortVersionString') !== manifest.version ||
          plistValue(info, 'CFBundleIdentifier') !== 'boo.peekaboo.mac') {
        throw new Error('Peekaboo.app signed source/version mismatch');
      }
    } else if (expectedRoot === 'Playground.app') {
      const info = path.join(extractedRoot, 'Contents', 'Info.plist');
      const receipt = JSON.parse(await readFile(path.join(extractedRoot, 'Contents', 'Resources',
        'PeekabooPlaygroundSource.json'), 'utf8'));
      exactKeys(receipt, ['version', 'source_commit', 'source_tree', 'dependency_lock_path',
        'dependency_lock_sha256', 'workspace', 'scheme', 'configuration', 'bundle_identifier',
        'marketing_version', 'developer_dir', 'xcodebuild_version', 'sdk_version', 'swiftc_version'],
      'Playground embedded source receipt');
      if (plistValue(info, 'CFBundleIdentifier') !== 'boo.peekaboo.playground.debug' ||
          receipt.version !== 2 || receipt.source_commit !== manifest.source_commit ||
          receipt.marketing_version !== manifest.version ||
          receipt.dependency_lock_path !== manifest.dependency_lock_path ||
          receipt.dependency_lock_sha256 !== manifest.dependency_lock_sha256 ||
          receipt.workspace !== 'Apps/Peekaboo.xcworkspace' || receipt.scheme !== 'Playground' ||
          receipt.configuration !== 'Debug' || receipt.bundle_identifier !== 'boo.peekaboo.playground.debug' ||
          receipt.developer_dir !== manifest.toolchain.developer_dir ||
          receipt.xcodebuild_version !== manifest.toolchain.xcodebuild_version ||
          receipt.sdk_version !== manifest.toolchain.sdk_version ||
          receipt.swiftc_version !== manifest.toolchain.swiftc_version || !exactSource.test(receipt.source_tree)) {
        throw new Error('Playground signed provenance receipt mismatch');
      }
    }
    if (expectedRoot === 'PeekabooQualificationNode.app') {
      const nodeBinary = path.join(extractedRoot, 'Contents', 'MacOS', 'node');
      const info = path.join(extractedRoot, 'Contents', 'Info.plist');
      if (plistValue(info, 'CFBundleIdentifier') !== 'boo.peekaboo.qualification-node' ||
          plistValue(info, 'CFBundleShortVersionString') !== '24.15.0') {
        throw new Error('qualification Node Info.plist mismatch');
      }
      const embeddedSource = JSON.parse(await readFile(path.join(extractedRoot, 'Contents', 'Resources',
        'PeekabooQualificationNodeSource.json'), 'utf8'));
      if (embeddedSource.runtime_version !== record.runtime.version ||
          embeddedSource.identifier !== record.runtime.identifier ||
          embeddedSource.executable_path !== record.runtime.executable_path ||
          JSON.stringify(embeddedSource.architectures) !== JSON.stringify(record.runtime.architectures) ||
          embeddedSource.universal_binary_sha256 !== record.runtime.unsigned_binary_sha256 ||
          embeddedSource.universal_binary_size !== record.runtime.unsigned_binary_size ||
          JSON.stringify(embeddedSource.license) !== JSON.stringify(record.runtime.license) ||
          JSON.stringify(embeddedSource.entitlements) !== JSON.stringify(record.runtime.entitlements) ||
          JSON.stringify(embeddedSource.inputs) !== JSON.stringify(record.runtime.inputs)) {
        throw new Error('embedded Node source receipt differs from terminal manifest');
      }
      for (const architecture of ['arm64', 'x86_64']) {
        const details = inspectSignature(nodeBinary, {
          identifier: 'boo.peekaboo.qualification-node',
          architecture
        });
        if (signatureField(details, 'CDHash') !== record.runtime.binary_cdhashes[architecture]) {
          throw new Error(`Node ${architecture} identity mismatch`);
        }
      }
      if (!fixtureTools) {
        for (const architecture of ['arm64', 'x86_64']) {
          const result = spawnSync(codesignBinary,
            ['-d', '--entitlements', ':-', '--arch', architecture, nodeBinary], { encoding: 'utf8' });
          if (result.status !== 0 || !result.stdout.trim()) {
            throw new Error(`Node ${architecture} entitlements inspection failed`);
          }
          const actual = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], {
            input: result.stdout, encoding: 'utf8'
          });
          const expected = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-',
            path.join(extractedRoot, record.runtime.entitlements.path)], { encoding: 'utf8' });
          if (actual.status !== 0 || expected.status !== 0 || actual.stdout !== expected.stdout) {
            throw new Error(`Node ${architecture} JIT entitlements mismatch`);
          }
        }
      }
    }
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

async function validateBoundFile(record, label, {
  expectedPath,
  treePath = null,
  embeddedKey = null,
  extraKeys = []
} = {}) {
  const tree = treePath !== null;
  exactKeys(record, ['path', 'sha256', 'size', 'cdhash', 'source_commit', ...(tree ? ['tree_manifest'] : []),
    ...(embeddedKey ? [embeddedKey] : []), ...extraKeys], label);
  if (record.path !== expectedPath || path.basename(record.path) !== record.path) {
    throw new Error(`${label} path differs`);
  }
  const target = path.join(root, record.path);
  if (!exactSHA.test(record.sha256) || await sha256(target) !== record.sha256) throw new Error(`${label} hash mismatch`);
  if ((await stat(target)).size !== record.size) throw new Error(`${label} size mismatch`);
  if (run('/usr/bin/xattr', ['-r', target]).trim()) throw new Error(`${label} archive contains xattrs`);
  if (!exactCDHash.test(record.cdhash) || record.source_commit !== manifest.source_commit) {
    throw new Error(`${label} identity/source mismatch`);
  }
  if (embeddedKey && !exactSHA.test(record[embeddedKey])) throw new Error(`${label} embedded receipt hash is invalid`);
  if (tree) {
    exactKeys(record.tree_manifest, ['path', 'sha256'], `${label}.tree_manifest`);
    if (record.tree_manifest.path !== treePath || path.basename(record.tree_manifest.path) !== treePath) {
      throw new Error(`${label} tree path differs`);
    }
    const retainedTreePath = path.join(root, record.tree_manifest.path);
    if (!exactSHA.test(record.tree_manifest.sha256) ||
        await sha256(retainedTreePath) !== record.tree_manifest.sha256) {
      throw new Error(`${label} tree receipt mismatch`);
    }
    const tree = JSON.parse(await readFile(retainedTreePath, 'utf8'));
    exactKeys(tree, ['version', 'entries'], `${label} tree`);
    if (tree.version !== 1 || !Array.isArray(tree.entries) || tree.entries.length === 0) {
      throw new Error(`${label} tree is empty`);
    }
  }
}

function validateNotary(receipt, kind, label, expectedIdentifiers) {
  exactKeys(receipt, ['version', 'kind', 'id', 'status', 'submission', 'code_identity', 'final_artifact'], label);
  exactKeys(receipt.submission, ['path', 'sha256', 'size'], `${label}.submission`);
  exactKeys(receipt.code_identity, ['authority', 'identifier', 'team_id', 'cdhash', 'architectures', 'cdhashes'],
    `${label}.code_identity`);
  if (receipt.version !== 2 || receipt.kind !== kind || receipt.status !== 'Accepted' ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(receipt.id) ||
      receipt.submission.path !== `notary/submissions/${receipt.submission.sha256}` ||
      !exactSHA.test(receipt.submission.sha256) || !Number.isSafeInteger(receipt.submission.size) ||
      receipt.submission.size <= 0 ||
      receipt.code_identity.authority !== 'Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)' ||
      receipt.code_identity.team_id !== 'FWJYW4S8P8' ||
      typeof receipt.code_identity.identifier !== 'string' || !receipt.code_identity.identifier ||
      !exactCDHash.test(receipt.code_identity.cdhash) ||
      (expectedIdentifiers && !expectedIdentifiers.includes(receipt.code_identity.identifier))) {
    throw new Error(`${label} is invalid`);
  }
  if (!Array.isArray(receipt.code_identity.architectures) || receipt.code_identity.architectures.length === 0 ||
      new Set(receipt.code_identity.architectures).size !== receipt.code_identity.architectures.length ||
      receipt.code_identity.architectures.some((architecture) =>
        !['arm64', 'x86_64', 'container'].includes(architecture)) ||
      JSON.stringify(Object.keys(receipt.code_identity.cdhashes).sort()) !==
        JSON.stringify([...receipt.code_identity.architectures].sort()) ||
      Object.values(receipt.code_identity.cdhashes).some((cdhash) => !exactCDHash.test(cdhash)) ||
      receipt.code_identity.cdhash !==
        (receipt.code_identity.cdhashes.arm64 ?? receipt.code_identity.cdhashes.x86_64 ??
          receipt.code_identity.cdhashes.container)) {
    throw new Error(`${label} architecture identities are invalid`);
  }
  if (kind === 'app' || kind === 'controller_tree' || kind === 'cli_tree') {
    exactKeys(receipt.final_artifact, ['tree_manifest_sha256', 'tree_manifest_size'], `${label}.final_artifact`);
    if (!exactSHA.test(receipt.final_artifact.tree_manifest_sha256) ||
        !Number.isSafeInteger(receipt.final_artifact.tree_manifest_size) ||
        receipt.final_artifact.tree_manifest_size <= 0) throw new Error(`${label} tree receipt invalid`);
  } else {
    exactKeys(receipt.final_artifact, ['sha256', 'size'], `${label}.final_artifact`);
    if (!exactSHA.test(receipt.final_artifact.sha256) || !Number.isSafeInteger(receipt.final_artifact.size) ||
        receipt.final_artifact.size <= 0) {
      throw new Error(`${label} final artifact is invalid`);
    }
  }
}

exactKeys(manifest, ['schema', 'phase', 'root', 'version', 'source_commit', 'dependency_lock_path',
  'dependency_lock_sha256', 'toolchain', 'signing', 'notarization', 'artifacts', 'cli', 'app',
  'playground', 'monitor', 'controller', 'verification', 'portable'], 'manifest');
if (manifest.schema !== 7 || manifest.phase !== 'candidate_verified_not_installed' || manifest.root !== '.' ||
    typeof manifest.version !== 'string' || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(manifest.version) ||
    !exactSource.test(manifest.source_commit) ||
    manifest.dependency_lock_path !== 'Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved' ||
    !exactSHA.test(manifest.dependency_lock_sha256)) {
  throw new Error('manifest source contract is invalid');
}
const expectedRootEntries = [
  'Peekaboo-' + manifest.version + '.app.zip',
  'Peekaboo-' + manifest.version + '.dmg',
  'PeekabooQualificationNode-24.15.0.app.zip',
  'Playground-' + manifest.version + '.app.zip',
  'checksums.txt',
  'cli-notary-tree.json',
  'cli-tree.json',
  'notary',
  'peekaboo-app-tree.json',
  'peekaboo-dmg-payload.json',
  'peekaboo-macos-universal.tar.gz',
  'playground-app-tree.json',
  'qualification-node-app-tree.json',
  'qualification',
  'qualification-tree.json',
  'controller-source-manifest.json',
  'qualification-source',
  'qualification-source-tree.json',
  'terminal-artifacts.json',
  'tools'
].sort();
const rootEntries = (await readdir(root)).sort();
if (JSON.stringify(rootEntries) !== JSON.stringify(expectedRootEntries)) throw new Error('unbound root artifact exists');
const rootDirectories = new Set(['notary', 'qualification', 'qualification-source', 'tools']);
for (const entry of expectedRootEntries) {
  const target = path.join(root, entry);
  if (rootDirectories.has(entry)) await requireDirectory(target, `root/${entry}`);
  else await requireRegularFile(target, `root/${entry}`);
}
exactKeys(manifest.toolchain, ['developer_dir', 'xcodebuild_version', 'sdk_version', 'swiftc_version'], 'toolchain');
exactKeys(manifest.signing, ['authority', 'team_id', 'release_helper'], 'signing');
exactKeys(manifest.signing.release_helper, ['commit', 'executable_sha256', 'library_sha256'], 'release helper');
if (manifest.signing.authority !== 'Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)' ||
    manifest.signing.team_id !== 'FWJYW4S8P8' ||
    manifest.signing.release_helper.commit !== '20ab9a5e6bb1107788366726868f1a9b4c16d953' ||
    manifest.signing.release_helper.executable_sha256 !==
      'e65e06ef89ec90ebfc537d28748a3c4de8ce89bd09b51e4d67ba4bdd95427255' ||
    manifest.signing.release_helper.library_sha256 !==
      'c29d3c46506c2d0bd2db7ab688bd3108d54e8824074a4fe800de6e3fe17284c9') {
  throw new Error('signing identity or release helper mismatch');
}
exactKeys(manifest.portable, ['validator', 'tree_generator', 'archive_policy', 'dmg_policy', 'source_tree'],
  'portable tools');
exactKeys(manifest.portable.validator, ['path', 'sha256'], 'portable validator');
exactKeys(manifest.portable.tree_generator, ['path', 'sha256'], 'portable tree generator');
exactKeys(manifest.portable.archive_policy, ['path', 'sha256'], 'portable archive policy');
exactKeys(manifest.portable.dmg_policy, ['path', 'sha256'], 'portable DMG policy');
exactKeys(manifest.portable.source_tree, ['path', 'tree_manifest'], 'portable source tree');
exactKeys(manifest.portable.source_tree.tree_manifest, ['path', 'sha256'], 'portable source tree manifest');
if (manifest.portable.validator.path !== 'tools/validate-terminal-artifact-manifest.mjs' ||
    manifest.portable.tree_generator.path !== 'tools/artifact-tree-manifest.rb' ||
    manifest.portable.archive_policy.path !== 'tools/terminal-archive-policy.mjs' ||
    manifest.portable.dmg_policy.path !== 'tools/terminal-dmg-payload.mjs' ||
    manifest.portable.source_tree.path !== 'qualification-source' ||
    manifest.portable.source_tree.tree_manifest.path !== 'qualification-source-tree.json') {
  throw new Error('portable tool paths differ');
}
const trustedTools = new Map([
  [manifest.portable.validator.path, fileURLToPath(import.meta.url)],
  [manifest.portable.tree_generator.path, path.join(scriptDirectory, 'artifact-tree-manifest.rb')],
  [manifest.portable.archive_policy.path, path.join(scriptDirectory, 'terminal-archive-policy.mjs')],
  [manifest.portable.dmg_policy.path, path.join(scriptDirectory, 'terminal-dmg-payload.mjs')]
]);
for (const retainedTool of [manifest.portable.validator, manifest.portable.tree_generator,
  manifest.portable.archive_policy, manifest.portable.dmg_policy]) {
  const retainedPath = path.join(root, retainedTool.path);
  const trustedPath = trustedTools.get(retainedTool.path);
  await requireRegularFile(retainedPath, retainedTool.path);
  await requireRegularFile(trustedPath, `trusted ${retainedTool.path}`);
  const retainedHash = await sha256(retainedPath);
  if (!exactSHA.test(retainedTool.sha256) || retainedHash !== retainedTool.sha256 ||
      retainedHash !== await sha256(trustedPath)) {
    throw new Error(`portable retained tool differs from trusted validator sibling: ${retainedTool.path}`);
  }
}
const sourceTreeManifestPath = path.join(root, manifest.portable.source_tree.tree_manifest.path);
await requireRegularFile(sourceTreeManifestPath, 'portable source tree manifest');
if (!exactSHA.test(manifest.portable.source_tree.tree_manifest.sha256) ||
    await sha256(sourceTreeManifestPath) !== manifest.portable.source_tree.tree_manifest.sha256) {
  throw new Error('portable source tree manifest hash mismatch');
}
const trustedTreeGenerator = trustedTools.get(manifest.portable.tree_generator.path);
const trustedArchivePolicy = trustedTools.get(manifest.portable.archive_policy.path);
const trustedDMGPolicy = trustedTools.get(manifest.portable.dmg_policy.path);
const archivePolicy = await import(pathToFileURL(trustedArchivePolicy).href);
const dmgPolicy = await import(pathToFileURL(trustedDMGPolicy).href);
await requireDirectory(path.join(root, manifest.portable.source_tree.path), 'portable source tree');
const generatedSourceTree = run('/usr/bin/ruby', [trustedTreeGenerator,
  path.join(root, manifest.portable.source_tree.path)]);
if (generatedSourceTree !== await readFile(path.join(root,
  manifest.portable.source_tree.tree_manifest.path), 'utf8')) throw new Error('portable source tree differs');
const retainedLockPath = path.join(root, manifest.portable.source_tree.path, manifest.dependency_lock_path);
await requireRegularFile(retainedLockPath, 'retained canonical dependency lock');
if (await sha256(retainedLockPath) !== manifest.dependency_lock_sha256) {
  throw new Error('retained canonical dependency lock differs');
}
exactKeys(manifest.cli, ['sha256', 'cdhash'], 'cli compatibility');
exactKeys(manifest.app, ['source_commit', 'zip_sha256', 'cdhash'], 'app compatibility');
exactKeys(manifest.playground, ['source_commit', 'zip_sha256', 'cdhash'], 'playground compatibility');
exactKeys(manifest.monitor, ['source_commit', 'source_path', 'source_sha256', 'relative_path',
  'executable_sha256', 'cdhash'], 'monitor compatibility');
exactKeys(manifest.controller, ['source_commit', 'source_manifest_sha256', 'relative_path',
  'executable_sha256', 'cdhash', 'team_id', 'authority', 'signing_identifier', 'architectures'],
'controller compatibility');
exactKeys(manifest.verification, ['cli_source', 'cli_native_only', 'monitor_source', 'monitor_native_only',
  'controller_source', 'controller_native_only', 'app_source', 'app_native_only', 'playground_native_only'],
'verification compatibility');
if (manifest.app.source_commit !== manifest.source_commit || manifest.playground.source_commit !== manifest.source_commit ||
    manifest.monitor.source_commit !== manifest.source_commit || manifest.controller.source_commit !== manifest.source_commit ||
    manifest.monitor.source_path !== 'scripts/support/background-computer-use-probe.swift' ||
    manifest.monitor.relative_path !== 'qualification/background-computer-use-probe' ||
    manifest.controller.relative_path !== 'qualification/peekaboo-certification-controller' ||
    manifest.controller.team_id !== 'FWJYW4S8P8' ||
    manifest.controller.authority !== 'Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)' ||
    manifest.controller.signing_identifier !== 'boo.peekaboo.peekaboo-certification-controller' ||
    JSON.stringify(manifest.controller.architectures) !== JSON.stringify(['arm64', 'x86_64']) ||
    Object.values(manifest.verification).some((value) => value !== true)) {
  throw new Error('schema-7 compatibility projection mismatch');
}
exactKeys(manifest.artifacts, ['cli', 'peekaboo_app_zip', 'peekaboo_dmg', 'playground_app_zip',
  'qualification_node_app_zip', 'qualification_monitor', 'certification_controller'], 'artifacts');
exactKeys(manifest.notarization, ['cli', 'peekaboo_app', 'peekaboo_dmg', 'playground_app',
  'qualification_node_app', 'certification_controller'], 'notarization');

validateNotary(manifest.notarization.cli, 'cli_tree', 'notarization.cli', ['boo.peekaboo.peekaboo']);
validateNotary(manifest.notarization.peekaboo_app, 'app', 'notarization.peekaboo_app', ['boo.peekaboo.mac']);
validateNotary(manifest.notarization.playground_app, 'app', 'notarization.playground_app',
  ['boo.peekaboo.playground.debug']);
validateNotary(manifest.notarization.peekaboo_dmg, 'dmg', 'notarization.peekaboo_dmg', null);
validateNotary(manifest.notarization.qualification_node_app, 'app', 'notarization.qualification_node_app',
  ['boo.peekaboo.qualification-node']);
validateNotary(manifest.notarization.certification_controller, 'controller_tree',
  'notarization.certification_controller', ['boo.peekaboo.peekaboo-certification-controller']);
await validateBoundFile(manifest.artifacts.cli, 'artifacts.cli', {
  expectedPath: 'peekaboo-macos-universal.tar.gz',
  treePath: 'cli-tree.json',
  extraKeys: ['cdhashes', 'notarized_tree_manifest']
});
exactKeys(manifest.artifacts.cli.notarized_tree_manifest, ['path', 'sha256'], 'CLI notarized tree manifest');
if (manifest.artifacts.cli.notarized_tree_manifest.path !== 'cli-notary-tree.json' ||
    !exactSHA.test(manifest.artifacts.cli.notarized_tree_manifest.sha256) ||
    await sha256(path.join(root, 'cli-notary-tree.json')) !==
      manifest.artifacts.cli.notarized_tree_manifest.sha256) {
  throw new Error('CLI notarized tree manifest mismatch');
}
exactKeys(manifest.artifacts.cli.cdhashes, ['arm64', 'x86_64'], 'CLI architecture CDHashes');
if (!exactCDHash.test(manifest.artifacts.cli.cdhashes.arm64) ||
    !exactCDHash.test(manifest.artifacts.cli.cdhashes.x86_64) ||
    manifest.artifacts.cli.cdhash !== manifest.artifacts.cli.cdhashes.arm64) {
  throw new Error('CLI architecture CDHashes are invalid');
}
await validateBoundFile(manifest.artifacts.peekaboo_app_zip, 'artifacts.peekaboo_app_zip', {
  expectedPath: `Peekaboo-${manifest.version}.app.zip`,
  treePath: 'peekaboo-app-tree.json'
});
await validateBoundFile(manifest.artifacts.peekaboo_dmg, 'artifacts.peekaboo_dmg', {
  expectedPath: `Peekaboo-${manifest.version}.dmg`,
  extraKeys: ['payload_receipt']
});
exactKeys(manifest.artifacts.peekaboo_dmg.payload_receipt, ['path', 'sha256'], 'DMG payload receipt');
if (manifest.artifacts.peekaboo_dmg.payload_receipt.path !== 'peekaboo-dmg-payload.json' ||
    !exactSHA.test(manifest.artifacts.peekaboo_dmg.payload_receipt.sha256) ||
    await sha256(path.join(root, manifest.artifacts.peekaboo_dmg.payload_receipt.path)) !==
      manifest.artifacts.peekaboo_dmg.payload_receipt.sha256) {
  throw new Error('DMG payload receipt hash mismatch');
}
await validateBoundFile(manifest.artifacts.playground_app_zip, 'artifacts.playground_app_zip', {
  expectedPath: `Playground-${manifest.version}.app.zip`,
  treePath: 'playground-app-tree.json',
  embeddedKey: 'embedded_manifest_sha256'
});
await validateBoundFile(manifest.artifacts.qualification_node_app_zip, 'artifacts.qualification_node_app_zip', {
  expectedPath: 'PeekabooQualificationNode-24.15.0.app.zip',
  treePath: 'qualification-node-app-tree.json',
  embeddedKey: 'embedded_runtime_manifest_sha256',
  extraKeys: ['runtime']
});
const monitorArtifact = manifest.artifacts.qualification_monitor;
exactKeys(monitorArtifact, ['path', 'sha256', 'size', 'cdhash', 'cdhashes', 'source_commit', 'identifier', 'architectures',
  'source', 'tree_manifest'], 'artifacts.qualification_monitor');
exactKeys(monitorArtifact.cdhashes, ['arm64', 'x86_64'], 'qualification monitor architecture CDHashes');
exactKeys(monitorArtifact.source, ['path', 'sha256'], 'qualification monitor source');
exactKeys(monitorArtifact.tree_manifest, ['path', 'sha256'], 'qualification monitor tree manifest');
if (monitorArtifact.path !== 'qualification/background-computer-use-probe' ||
    monitorArtifact.identifier !== 'boo.peekaboo.background-computer-use-probe' ||
    JSON.stringify(monitorArtifact.architectures) !== JSON.stringify(['arm64', 'x86_64']) ||
    monitorArtifact.source_commit !== manifest.source_commit || !exactSHA.test(monitorArtifact.sha256) ||
    !exactCDHash.test(monitorArtifact.cdhash) || !exactCDHash.test(monitorArtifact.cdhashes.arm64) ||
    !exactCDHash.test(monitorArtifact.cdhashes.x86_64) || monitorArtifact.cdhash !== monitorArtifact.cdhashes.arm64 ||
    !Number.isSafeInteger(monitorArtifact.size) ||
    monitorArtifact.size <= 0 || monitorArtifact.source.path !== manifest.monitor.source_path ||
    !exactSHA.test(monitorArtifact.source.sha256) || monitorArtifact.tree_manifest.path !== 'qualification-tree.json' ||
    !exactSHA.test(monitorArtifact.tree_manifest.sha256)) {
  throw new Error('qualification monitor artifact contract mismatch');
}
const controller = manifest.artifacts.certification_controller;
exactKeys(controller, ['path', 'sha256', 'size', 'cdhash', 'cdhashes', 'source_commit', 'identifier', 'architectures',
  'source_manifest', 'tree_manifest'], 'artifacts.certification_controller');
exactKeys(controller.cdhashes, ['arm64', 'x86_64'], 'controller architecture CDHashes');
exactKeys(controller.source_manifest, ['path', 'sha256', 'aggregate_sha256'], 'controller source manifest');
exactKeys(controller.tree_manifest, ['path', 'sha256'], 'controller tree manifest');
if (controller.path !== 'qualification/peekaboo-certification-controller' ||
    controller.identifier !== 'boo.peekaboo.peekaboo-certification-controller' ||
    JSON.stringify(controller.architectures) !== JSON.stringify(['arm64', 'x86_64']) ||
    controller.source_commit !== manifest.source_commit || !exactSHA.test(controller.sha256) ||
    !exactCDHash.test(controller.cdhash) || !exactCDHash.test(controller.cdhashes.arm64) ||
    !exactCDHash.test(controller.cdhashes.x86_64) || controller.cdhash !== controller.cdhashes.arm64 ||
    controller.tree_manifest.path !== 'qualification-tree.json' ||
    controller.source_manifest.path !== 'controller-source-manifest.json' ||
    !exactSHA.test(controller.source_manifest.sha256) || !exactSHA.test(controller.source_manifest.aggregate_sha256) ||
    !exactSHA.test(controller.tree_manifest.sha256)) throw new Error('controller artifact contract mismatch');
const controllerPath = path.join(root, controller.path);
if (await sha256(controllerPath) !== controller.sha256 || (await stat(controllerPath)).size !== controller.size ||
    await sha256(path.join(root, controller.tree_manifest.path)) !== controller.tree_manifest.sha256) {
  throw new Error('controller bytes or tree receipt mismatch');
}
if (await sha256(path.join(root, controller.source_manifest.path)) !== controller.source_manifest.sha256 ||
    controller.source_manifest.aggregate_sha256 !== manifest.controller.source_manifest_sha256) {
  throw new Error('controller source receipt mismatch');
}
const controllerSourceReceipt = JSON.parse(await readFile(path.join(root, controller.source_manifest.path), 'utf8'));
exactKeys(controllerSourceReceipt, ['version', 'catalog_path', 'catalog_sha256', 'aggregate_sha256', 'files'],
  'controller source receipt');
const retainedCatalogPath = path.join(root, manifest.portable.source_tree.path,
  requireSafeRelativePath(controllerSourceReceipt.catalog_path, 'controller catalog path'));
const retainedCatalog = JSON.parse(await readFile(retainedCatalogPath, 'utf8'));
const catalogSourceManifest = retainedCatalog.current_build_source?.controller_source_manifest;
if (controllerSourceReceipt.version !== 1 ||
    controllerSourceReceipt.catalog_path !== 'scripts/multi-target-certification-catalog.json' ||
    await sha256(retainedCatalogPath) !== controllerSourceReceipt.catalog_sha256 ||
    !Array.isArray(catalogSourceManifest) ||
    JSON.stringify(catalogSourceManifest) !== JSON.stringify(controllerSourceReceipt.files) ||
    controllerSourceReceipt.aggregate_sha256 !== controller.source_manifest.aggregate_sha256 ||
    aggregateSHA256('certification-controller-source-manifest', controllerSourceReceipt.files) !==
      controllerSourceReceipt.aggregate_sha256) {
  throw new Error('controller source aggregate mismatch');
}
const sourcePaths = new Set();
for (const sourceFile of controllerSourceReceipt.files) {
  exactKeys(sourceFile, ['path', 'sha256'], 'controller source file');
  requireSafeRelativePath(sourceFile.path, 'controller source file path');
  if (sourcePaths.has(sourceFile.path) || !exactSHA.test(sourceFile.sha256) ||
      await sha256(path.join(root, manifest.portable.source_tree.path, sourceFile.path)) !== sourceFile.sha256) {
    throw new Error('controller source file mismatch');
  }
  sourcePaths.add(sourceFile.path);
}
if (manifest.app.zip_sha256 !== manifest.artifacts.peekaboo_app_zip.sha256 ||
    manifest.app.cdhash !== manifest.artifacts.peekaboo_app_zip.cdhash ||
    manifest.playground.zip_sha256 !== manifest.artifacts.playground_app_zip.sha256 ||
    manifest.playground.cdhash !== manifest.artifacts.playground_app_zip.cdhash ||
    manifest.monitor.executable_sha256 !== monitorArtifact.sha256 ||
    manifest.monitor.cdhash !== monitorArtifact.cdhash ||
    manifest.monitor.source_sha256 !== monitorArtifact.source.sha256 ||
    manifest.controller.executable_sha256 !== controller.sha256 || manifest.controller.cdhash !== controller.cdhash) {
  throw new Error('schema-7 artifact projection differs from rich artifact records');
}
const dmgSignatureDetails = inspectSignature(path.join(root, manifest.artifacts.peekaboo_dmg.path), {
  identifier: manifest.notarization.peekaboo_dmg.code_identity.identifier
});
if (signatureField(dmgSignatureDetails, 'CDHash') !== manifest.artifacts.peekaboo_dmg.cdhash) {
  throw new Error('DMG code identity mismatch');
}
const retainedDMGPayload = JSON.parse(await readFile(path.join(root,
  manifest.artifacts.peekaboo_dmg.payload_receipt.path), 'utf8'));
const observedDMGPayload = await dmgPolicy.inspectDMGPayload({
  dmgPath: path.join(root, manifest.artifacts.peekaboo_dmg.path),
  expectedAppTree: path.join(root, manifest.artifacts.peekaboo_app_zip.tree_manifest.path),
  treeGenerator: trustedTreeGenerator
});
if (JSON.stringify(observedDMGPayload) !== JSON.stringify(retainedDMGPayload)) {
  throw new Error('DMG mounted payload differs from receipt');
}
await extractAndCompare(manifest.artifacts.cli, 'tar', 'peekaboo-macos-universal', 'boo.peekaboo.peekaboo');
await extractAndCompare(manifest.artifacts.peekaboo_app_zip, 'zip', 'Peekaboo.app', 'boo.peekaboo.mac');
await extractAndCompare(manifest.artifacts.playground_app_zip, 'zip', 'Playground.app',
  'boo.peekaboo.playground.debug');
await extractAndCompare(manifest.artifacts.qualification_node_app_zip, 'zip',
  'PeekabooQualificationNode.app', 'boo.peekaboo.qualification-node');
if (!exactSHA.test(manifest.artifacts.playground_app_zip.embedded_manifest_sha256)) {
  throw new Error('Playground embedded manifest hash is invalid');
}
if (manifest.notarization.peekaboo_app.final_artifact.tree_manifest_sha256 !==
    manifest.artifacts.peekaboo_app_zip.tree_manifest.sha256 ||
    manifest.notarization.playground_app.final_artifact.tree_manifest_sha256 !==
    manifest.artifacts.playground_app_zip.tree_manifest.sha256 ||
    manifest.notarization.qualification_node_app.final_artifact.tree_manifest_sha256 !==
    manifest.artifacts.qualification_node_app_zip.tree_manifest.sha256 ||
    manifest.notarization.certification_controller.final_artifact.tree_manifest_sha256 !==
    controller.tree_manifest.sha256 ||
    manifest.notarization.peekaboo_dmg.final_artifact.sha256 !== manifest.artifacts.peekaboo_dmg.sha256 ||
    manifest.notarization.peekaboo_dmg.final_artifact.size !== manifest.artifacts.peekaboo_dmg.size) {
  throw new Error('notary receipt final artifact binding mismatch');
}
for (const [receipt, treeRecord] of [
  [manifest.notarization.peekaboo_app, manifest.artifacts.peekaboo_app_zip.tree_manifest],
  [manifest.notarization.playground_app, manifest.artifacts.playground_app_zip.tree_manifest],
  [manifest.notarization.qualification_node_app, manifest.artifacts.qualification_node_app_zip.tree_manifest],
  [manifest.notarization.certification_controller, controller.tree_manifest]
]) {
  if (receipt.final_artifact.tree_manifest_size !== (await stat(path.join(root, treeRecord.path))).size) {
    throw new Error('notary tree receipt size mismatch');
  }
}
const nodeRuntime = manifest.artifacts.qualification_node_app_zip.runtime;
exactKeys(nodeRuntime, ['version', 'identifier', 'executable_path', 'architectures', 'binary_sha256',
  'binary_cdhashes', 'binary_size', 'unsigned_binary_sha256', 'unsigned_binary_size',
  'license', 'entitlements', 'inputs'], 'qualification node runtime');
exactKeys(nodeRuntime.binary_cdhashes, ['arm64', 'x86_64'], 'qualification node CDHashes');
exactKeys(nodeRuntime.license, ['path', 'sha256'], 'qualification node license');
exactKeys(nodeRuntime.entitlements, ['path', 'sha256'], 'qualification node entitlements');
exactKeys(nodeRuntime.inputs, ['arm64', 'x86_64'], 'qualification node inputs');
for (const architecture of ['arm64', 'x86_64']) {
  exactKeys(nodeRuntime.inputs[architecture], ['url', 'archive_sha256', 'binary_sha256'], `node input ${architecture}`);
}
if (nodeRuntime.version !== '24.15.0' || nodeRuntime.identifier !== 'boo.peekaboo.qualification-node' ||
    nodeRuntime.executable_path !== 'Contents/MacOS/node' ||
    JSON.stringify(nodeRuntime.architectures) !== JSON.stringify(['arm64', 'x86_64']) ||
    !exactSHA.test(nodeRuntime.unsigned_binary_sha256) || !Number.isSafeInteger(nodeRuntime.unsigned_binary_size) ||
    !exactSHA.test(nodeRuntime.binary_sha256) || !exactCDHash.test(nodeRuntime.binary_cdhashes.arm64) ||
    !exactCDHash.test(nodeRuntime.binary_cdhashes.x86_64) ||
    !Number.isSafeInteger(nodeRuntime.binary_size) ||
    nodeRuntime.license.path !== 'Contents/Resources/LICENSE' || !exactSHA.test(nodeRuntime.license.sha256) ||
    nodeRuntime.entitlements.path !== 'Contents/Resources/qualification-node.entitlements' ||
    !exactSHA.test(nodeRuntime.entitlements.sha256) ||
    typeof nodeRuntime.inputs.arm64.url !== 'string' || !nodeRuntime.inputs.arm64.url ||
    !exactSHA.test(nodeRuntime.inputs.arm64.archive_sha256) ||
    !exactSHA.test(nodeRuntime.inputs.arm64.binary_sha256) ||
    typeof nodeRuntime.inputs.x86_64.url !== 'string' || !nodeRuntime.inputs.x86_64.url ||
    !exactSHA.test(nodeRuntime.inputs.x86_64.archive_sha256) ||
    !exactSHA.test(nodeRuntime.inputs.x86_64.binary_sha256)) {
  throw new Error('qualification Node runtime contract mismatch');
}
if (!fixtureTools && (nodeRuntime.unsigned_binary_sha256 !==
      'f638dd249d1df9ff89764a312a510c55250f23ce40e977ac8b68a295161d6f3a' ||
    nodeRuntime.unsigned_binary_size !== 242234784 ||
    nodeRuntime.license.sha256 !== '4573185d56580da2b890ba34a85a409257640f1c5632eade4300137266194d18' ||
    nodeRuntime.entitlements.sha256 !== '6b8322742841af1b5b0e29b25383647950cf52de7f4e0567da0838cc59babdf1' ||
    nodeRuntime.inputs.arm64.url !== 'https://nodejs.org/dist/v24.15.0/node-v24.15.0-darwin-arm64.tar.gz' ||
    nodeRuntime.inputs.arm64.archive_sha256 !==
      '372331b969779ab5d15b949884fc6eaf88d5afe87bde8ba881d6400b9100ffc4' ||
    nodeRuntime.inputs.arm64.binary_sha256 !==
      '3200fbd9f7fd4410426dd541e10d1ab829d3472f270d743c7fabd1696c03fe32' ||
    nodeRuntime.inputs.x86_64.url !== 'https://nodejs.org/dist/v24.15.0/node-v24.15.0-darwin-x64.tar.gz' ||
    nodeRuntime.inputs.x86_64.archive_sha256 !==
      'ffd5ee293467927f3ee731a553eb88fd1f48cf74eebc2d74a6babe4af228673b' ||
    nodeRuntime.inputs.x86_64.binary_sha256 !==
      '2a249a6a7015b0555c3448a77d226c1f3c8f62bd133d89044a2e1518cd16c4b3')) {
  throw new Error('production qualification Node pins differ');
}
const cliTree = JSON.parse(await readFile(path.join(root, manifest.artifacts.cli.tree_manifest.path), 'utf8'));
const playgroundTree = JSON.parse(await readFile(path.join(root,
  manifest.artifacts.playground_app_zip.tree_manifest.path), 'utf8'));
const nodeTree = JSON.parse(await readFile(path.join(root,
  manifest.artifacts.qualification_node_app_zip.tree_manifest.path), 'utf8'));
const controllerTreePath = path.join(root, controller.tree_manifest.path);
const controllerTree = JSON.parse(await readFile(controllerTreePath, 'utf8'));
const fileEntry = (tree, entryPath, label) => {
  const matches = tree.entries.filter((entry) => entry.path === entryPath && entry.type === 'file');
  if (matches.length !== 1) throw new Error(`${label} tree entry is missing or duplicated`);
  return matches[0];
};
const cliExecutable = fileEntry(cliTree, 'peekaboo', 'CLI executable');
if (manifest.notarization.cli.final_artifact.tree_manifest_sha256 !==
      manifest.artifacts.cli.notarized_tree_manifest.sha256 ||
    manifest.notarization.cli.final_artifact.tree_manifest_size !==
      (await stat(path.join(root, manifest.artifacts.cli.notarized_tree_manifest.path))).size) {
  throw new Error('CLI notary receipt is not bound to the signed payload tree');
}
if (manifest.cli.sha256 !== cliExecutable.sha256 || manifest.cli.cdhash !== manifest.artifacts.cli.cdhash) {
  throw new Error('schema-7 CLI projection differs from archived executable');
}
if (manifest.notarization.cli.code_identity.cdhash !== manifest.artifacts.cli.cdhash ||
    JSON.stringify(canonicalValue(manifest.notarization.cli.code_identity.cdhashes)) !==
      JSON.stringify(canonicalValue(manifest.artifacts.cli.cdhashes)) ||
    manifest.notarization.peekaboo_app.code_identity.cdhash !== manifest.artifacts.peekaboo_app_zip.cdhash ||
    manifest.notarization.playground_app.code_identity.cdhash !== manifest.artifacts.playground_app_zip.cdhash ||
    manifest.notarization.qualification_node_app.code_identity.cdhash !==
      manifest.artifacts.qualification_node_app_zip.cdhash ||
    JSON.stringify(canonicalValue(manifest.notarization.qualification_node_app.code_identity.cdhashes)) !==
      JSON.stringify(canonicalValue(nodeRuntime.binary_cdhashes)) ||
    manifest.notarization.certification_controller.code_identity.cdhash !== controller.cdhash ||
    JSON.stringify(canonicalValue(manifest.notarization.certification_controller.code_identity.cdhashes)) !==
      JSON.stringify(canonicalValue(controller.cdhashes)) ||
    manifest.notarization.peekaboo_dmg.code_identity.cdhash !== manifest.artifacts.peekaboo_dmg.cdhash) {
  throw new Error('notary code identity is not bound to the artifact record');
}
const playgroundSource = fileEntry(playgroundTree,
  'Contents/Resources/PeekabooPlaygroundSource.json', 'Playground source manifest');
if (playgroundSource.sha256 !== manifest.artifacts.playground_app_zip.embedded_manifest_sha256) {
  throw new Error('Playground embedded manifest hash is not bound to the tree');
}
const nodeSource = fileEntry(nodeTree,
  'Contents/Resources/PeekabooQualificationNodeSource.json', 'Node source manifest');
const nodeExecutable = fileEntry(nodeTree, 'Contents/MacOS/node', 'Node executable');
const nodeLicense = fileEntry(nodeTree, nodeRuntime.license.path, 'Node license');
const nodeEntitlements = fileEntry(nodeTree, nodeRuntime.entitlements.path, 'Node entitlements');
if (nodeSource.sha256 !== manifest.artifacts.qualification_node_app_zip.embedded_runtime_manifest_sha256 ||
    nodeExecutable.sha256 !== nodeRuntime.binary_sha256 || nodeExecutable.size !== nodeRuntime.binary_size ||
    nodeLicense.sha256 !== nodeRuntime.license.sha256 ||
    nodeEntitlements.sha256 !== nodeRuntime.entitlements.sha256) {
  throw new Error('qualification Node runtime is not bound to its signed tree');
}
const qualificationRoot = path.join(root, 'qualification');
if (run('/usr/bin/xattr', ['-r', qualificationRoot]).trim()) throw new Error('controller tree contains xattrs');
const generatedControllerTree = run('/usr/bin/ruby', [trustedTreeGenerator,
  qualificationRoot]);
if (generatedControllerTree !== await readFile(controllerTreePath, 'utf8')) {
  throw new Error('retained controller tree differs from its receipt');
}
const controllerEntry = fileEntry(controllerTree, 'peekaboo-certification-controller', 'controller executable');
if (controllerEntry.sha256 !== controller.sha256 || controllerEntry.size !== controller.size) {
  throw new Error('controller executable differs from artifact record');
}
const monitorEntry = fileEntry(controllerTree, 'background-computer-use-probe', 'qualification monitor');
if (monitorEntry.sha256 !== monitorArtifact.sha256 || monitorEntry.size !== monitorArtifact.size ||
    monitorArtifact.tree_manifest.sha256 !== controller.tree_manifest.sha256) {
  throw new Error('qualification monitor differs from artifact record');
}
const qualificationRootEntries = controllerTree.entries.filter((entry) => entry.path !== '.');
if (controllerTree.entries.filter((entry) => entry.path === '.' && entry.type === 'directory').length !== 1 ||
    qualificationRootEntries.length === 0 || qualificationRootEntries.some((entry) =>
      entry.type !== 'file' || entry.path.includes('/'))) {
  throw new Error('qualification tree must contain only flat regular files');
}
for (const entry of qualificationRootEntries) {
  const candidatePath = path.join(qualificationRoot, entry.path);
  await requireRegularFile(candidatePath, `qualification/${entry.path}`);
  let expectedIdentifier;
  if (entry.path === 'peekaboo-certification-controller') {
    expectedIdentifier = 'boo.peekaboo.peekaboo-certification-controller';
  } else if (entry.path === 'background-computer-use-probe') {
    expectedIdentifier = 'boo.peekaboo.background-computer-use-probe';
  } else if (/^libswiftCompatibility[^/]*\.dylib$/.test(entry.path)) {
    expectedIdentifier = null;
  } else {
    throw new Error(`unexpected qualification helper: ${entry.path}`);
  }
  const details = inspectSignature(candidatePath, { identifier: expectedIdentifier });
  if (/^libswiftCompatibility/.test(entry.path) &&
      !signatureField(details, 'Identifier').startsWith('com.apple.dt.runtime.swiftCompatibility')) {
    throw new Error(`qualification runtime identifier mismatch: ${entry.path}`);
  }
}
const controllerDetails = inspectSignature(controllerPath, { identifier: controller.identifier, architecture: 'arm64' });
const controllerArchitectures = run('/usr/bin/lipo', ['-archs', controllerPath]).trim().split(/\s+/);
if (signatureField(controllerDetails, 'CDHash') !== controller.cdhash ||
    !controllerArchitectures.includes('arm64') || !controllerArchitectures.includes('x86_64') ||
    await machoPlistValue(controllerPath, 'PeekabooSourceCommit') !== manifest.source_commit ||
    await machoPlistValue(controllerPath, 'CFBundleShortVersionString') !== manifest.version ||
    await machoPlistValue(controllerPath, 'PeekabooCertificationSourceManifestSHA256') !==
      controllerSourceReceipt.aggregate_sha256 ||
    await machoPlistValue(controllerPath, 'PeekabooCertificationCatalogSHA256') !==
      controllerSourceReceipt.catalog_sha256) {
  throw new Error('controller signed identity or architectures mismatch');
}
for (const architecture of ['arm64', 'x86_64']) {
  const details = inspectSignature(controllerPath, { identifier: controller.identifier, architecture });
  if (signatureField(details, 'CDHash') !== controller.cdhashes[architecture]) {
    throw new Error(`controller ${architecture} CDHash mismatch`);
  }
}
const monitorPath = path.join(qualificationRoot, 'background-computer-use-probe');
const monitorDetails = inspectSignature(monitorPath, {
  identifier: 'boo.peekaboo.background-computer-use-probe',
  architecture: 'arm64'
});
const monitorArchitectures = run('/usr/bin/lipo', ['-archs', monitorPath]).trim().split(/\s+/);
if (signatureField(monitorDetails, 'CDHash') !== manifest.monitor.cdhash ||
    !monitorArchitectures.includes('arm64') || !monitorArchitectures.includes('x86_64') ||
    await sha256(monitorPath) !== manifest.monitor.executable_sha256 ||
    (await stat(monitorPath)).size !== monitorArtifact.size ||
    await machoPlistValue(monitorPath, 'PeekabooSourceCommit') !== manifest.source_commit ||
    await machoPlistValue(monitorPath, 'CFBundleShortVersionString') !== manifest.version ||
    await machoPlistValue(monitorPath, 'PeekabooCertificationSourceManifestSHA256') !==
      controllerSourceReceipt.aggregate_sha256 ||
    await machoPlistValue(monitorPath, 'PeekabooCertificationCatalogSHA256') !==
      controllerSourceReceipt.catalog_sha256 ||
    await machoPlistValue(monitorPath, 'PeekabooQualificationMonitorSourceSHA256') !==
      monitorArtifact.source.sha256 ||
    await sha256(path.join(root, manifest.portable.source_tree.path,
      'scripts/support/background-computer-use-probe.swift')) !==
      manifest.monitor.source_sha256) {
  throw new Error('qualification monitor identifier mismatch');
}
for (const architecture of ['arm64', 'x86_64']) {
  const details = inspectSignature(monitorPath, {
    identifier: 'boo.peekaboo.background-computer-use-probe', architecture
  });
  if (signatureField(details, 'CDHash') !== monitorArtifact.cdhashes[architecture]) {
    throw new Error(`qualification monitor ${architecture} CDHash mismatch`);
  }
}

const toolEntries = (await readdir(path.join(root, 'tools'))).sort();
if (JSON.stringify(toolEntries) !== JSON.stringify(['artifact-tree-manifest.rb', 'terminal-archive-policy.mjs',
  'terminal-dmg-payload.mjs', 'validate-terminal-artifact-manifest.mjs'].sort())) {
  throw new Error('unbound portable tool exists');
}
const notaryEntries = (await readdir(path.join(root, 'notary'))).sort();
const expectedNotary = ['cli.json', 'peekaboo-app.json', 'peekaboo-dmg.json', 'playground-app.json',
  'qualification-node-app.json', 'certification-controller.json', 'submissions'].sort();
if (JSON.stringify(notaryEntries) !== JSON.stringify(expectedNotary)) throw new Error('unbound notary receipt exists');
await requireDirectory(path.join(root, 'notary', 'submissions'), 'notary submissions');
for (const [fileName, receipt] of [
  ['cli.json', manifest.notarization.cli],
  ['peekaboo-app.json', manifest.notarization.peekaboo_app],
  ['peekaboo-dmg.json', manifest.notarization.peekaboo_dmg],
  ['playground-app.json', manifest.notarization.playground_app],
  ['qualification-node-app.json', manifest.notarization.qualification_node_app],
  ['certification-controller.json', manifest.notarization.certification_controller]
]) {
  const retained = JSON.parse(await readFile(path.join(root, 'notary', fileName), 'utf8'));
  if (JSON.stringify(retained) !== JSON.stringify(receipt)) throw new Error(`notary/${fileName} differs from manifest`);
  const submissionPath = path.join(root, receipt.submission.path);
  const submissionMetadata = await requireRegularFile(submissionPath, `${fileName} retained submission`);
  if (await sha256(submissionPath) !== receipt.submission.sha256 ||
      submissionMetadata.size !== receipt.submission.size) {
    throw new Error(`${fileName} retained submission differs from receipt`);
  }
}
const expectedSubmissions = [...new Set(Object.values(manifest.notarization)
  .map((receipt) => path.basename(receipt.submission.path)))].sort();
const retainedSubmissions = (await readdir(path.join(root, 'notary', 'submissions'))).sort();
if (JSON.stringify(retainedSubmissions) !== JSON.stringify(expectedSubmissions)) {
  throw new Error('unbound retained notary submission exists');
}
run('/usr/bin/shasum', ['-a', '256', '-c', 'checksums.txt'], { cwd: root });
process.stdout.write('validate-terminal-artifact-manifest: ok\n');
