#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { lstat, readFile, readdir, readlink } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  if (result.status !== 0) throw new Error(`${path.basename(command)} failed: ${result.stderr || result.stdout}`);
  return result.stdout;
}

async function sha256(filePath) {
  return createHash('sha256').update(await readFile(filePath)).digest('hex');
}

async function requireType(target, type, label) {
  const metadata = await lstat(target);
  if (metadata.isSymbolicLink() || (type === 'file' && !metadata.isFile()) ||
      (type === 'directory' && !metadata.isDirectory())) {
    throw new Error(`${label} has the wrong entry type`);
  }
  return metadata;
}

async function rejectExtendedAttributes(target, label) {
  const metadata = await lstat(target);
  const arguments_ = metadata.isSymbolicLink() ? ['-s', target] : [target];
  if (run('/usr/bin/xattr', arguments_).trim()) throw new Error(`${label} contains unbound xattrs`);
  if (metadata.isDirectory() && !metadata.isSymbolicLink()) {
    for (const child of await readdir(target)) {
      await rejectExtendedAttributes(path.join(target, child), `${label}/${child}`);
    }
  }
}

export async function inspectDMGPayload({ dmgPath = null, mountedRoot = null, expectedAppTree, treeGenerator }) {
  if ((!dmgPath && !mountedRoot) || (dmgPath && mountedRoot) || !expectedAppTree || !treeGenerator) {
    throw new Error('DMG payload inspection arguments are incomplete');
  }
  let mountPoint = mountedRoot;
  let attached = false;
  try {
    if (dmgPath) {
      await requireType(dmgPath, 'file', 'DMG');
      const attach = run('/usr/bin/hdiutil', ['attach', '-readonly', '-nobrowse', '-noautoopen', '-plist', dmgPath]);
      const converted = run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], { input: attach });
      const entities = JSON.parse(converted)['system-entities'];
      const mounts = Array.isArray(entities) ? entities.map((entity) => entity['mount-point']).filter(Boolean) : [];
      if (mounts.length !== 1 || typeof mounts[0] !== 'string') throw new Error('DMG did not produce one mount point');
      mountPoint = mounts[0];
      attached = true;
    }
    await requireType(mountPoint, 'directory', 'DMG mount');
    const requiredEntries = ['.VolumeIcon.icns', '.background', 'Applications', 'Peekaboo.app'].sort();
    const entries = (await readdir(mountPoint)).sort();
    const withoutOptionalFinderState = entries.filter((entry) => entry !== '.DS_Store');
    if (JSON.stringify(withoutOptionalFinderState) !== JSON.stringify(requiredEntries)) {
      throw new Error(`DMG root entries differ: ${entries.join(',')}`);
    }
    await rejectExtendedAttributes(mountPoint, 'DMG payload');
    const applications = path.join(mountPoint, 'Applications');
    const applicationsMetadata = await lstat(applications);
    if (!applicationsMetadata.isSymbolicLink() || await readlink(applications) !== '/Applications') {
      throw new Error('DMG Applications link differs');
    }
    const appPath = path.join(mountPoint, 'Peekaboo.app');
    await requireType(appPath, 'directory', 'DMG Peekaboo.app');
    const appTree = run('/usr/bin/ruby', [treeGenerator, appPath]);
    const expectedTree = await readFile(expectedAppTree, 'utf8');
    if (appTree !== expectedTree) throw new Error('DMG Peekaboo.app differs from notarized app tree');

    const background = path.join(mountPoint, '.background');
    await requireType(background, 'directory', 'DMG background');
    const backgroundTree = run('/usr/bin/ruby', [treeGenerator, background]);
    const metadata = [];
    for (const name of entries.includes('.DS_Store') ? ['.DS_Store', '.VolumeIcon.icns'] : ['.VolumeIcon.icns']) {
      const filePath = path.join(mountPoint, name);
      const fileMetadata = await requireType(filePath, 'file', `DMG ${name}`);
      metadata.push({ path: name, size: fileMetadata.size, sha256: await sha256(filePath) });
    }
    return {
      version: 1,
      root_entries: entries,
      applications_symlink: '/Applications',
      peekaboo_app_tree_sha256: createHash('sha256').update(expectedTree).digest('hex'),
      background_tree_sha256: createHash('sha256').update(backgroundTree).digest('hex'),
      metadata
    };
  } finally {
    if (attached && mountPoint) {
      run('/usr/bin/hdiutil', ['detach', mountPoint]);
    }
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  let dmgPath = null;
  let mountedRoot = null;
  let expectedAppTree = null;
  let treeGenerator = null;
  for (let index = 2; index < process.argv.length; index += 2) {
    const flag = process.argv[index];
    const value = process.argv[index + 1];
    if (!value) throw new Error(`${flag} requires a value`);
    if (flag === '--dmg') dmgPath = value;
    else if (flag === '--mounted-root') mountedRoot = value;
    else if (flag === '--expected-app-tree') expectedAppTree = value;
    else if (flag === '--tree-generator') treeGenerator = value;
    else throw new Error(`unknown argument: ${flag}`);
  }
  process.stdout.write(`${JSON.stringify(await inspectDMGPayload({
    dmgPath, mountedRoot, expectedAppTree, treeGenerator
  }))}\n`);
}
