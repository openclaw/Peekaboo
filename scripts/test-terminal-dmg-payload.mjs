import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { inspectDMGPayload } from './terminal-dmg-payload.mjs';

const scripts = path.dirname(fileURLToPath(import.meta.url));
const treeGenerator = path.join(scripts, 'artifact-tree-manifest.rb');
const temporary = await mkdtemp(path.join(os.tmpdir(), 'peekaboo-dmg-payload-test.'));
try {
  const root = path.join(temporary, 'volume');
  await mkdir(path.join(root, '.background'), { recursive: true });
  await mkdir(path.join(root, 'Peekaboo.app', 'Contents'), { recursive: true });
  await writeFile(path.join(root, '.DS_Store'), 'finder');
  await writeFile(path.join(root, '.VolumeIcon.icns'), 'icon');
  await writeFile(path.join(root, '.background', 'background.png'), 'background');
  await writeFile(path.join(root, 'Peekaboo.app', 'Contents', 'Info.plist'), 'app');
  await symlink('/Applications', path.join(root, 'Applications'));
  const expectedTree = path.join(temporary, 'app-tree.json');
  const { spawnSync } = await import('node:child_process');
  const tree = spawnSync('/usr/bin/ruby', [treeGenerator, path.join(root, 'Peekaboo.app')], { encoding: 'utf8' });
  assert.equal(tree.status, 0);
  await writeFile(expectedTree, tree.stdout);

  const receipt = await inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator });
  assert.equal(receipt.version, 1);
  assert.equal(receipt.applications_symlink, '/Applications');
  assert.equal(receipt.metadata.length, 2);

  await writeFile(path.join(root, 'unexpected'), 'unexpected');
  await assert.rejects(inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator }),
    /root entries differ/);
  await rm(path.join(root, 'unexpected'));
  spawnSync('/usr/bin/xattr', ['-w', 'com.openclaw.peekaboo.fixture', 'value',
    path.join(root, '.VolumeIcon.icns')]);
  await assert.rejects(inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator }),
    /unbound xattrs/);
  spawnSync('/usr/bin/xattr', ['-d', 'com.openclaw.peekaboo.fixture', path.join(root, '.VolumeIcon.icns')]);
  spawnSync('/usr/bin/xattr', ['-s', '-w', 'com.openclaw.peekaboo.fixture', 'value',
    path.join(root, 'Applications')]);
  await assert.rejects(inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator }),
    /Applications contains unbound xattrs/);
  spawnSync('/usr/bin/xattr', ['-s', '-d', 'com.openclaw.peekaboo.fixture', path.join(root, 'Applications')]);
  await writeFile(path.join(root, 'Peekaboo.app', 'Contents', 'Info.plist'), 'changed');
  await assert.rejects(inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator }),
    /differs from notarized app tree/);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

process.stdout.write('test-terminal-dmg-payload: ok\n');
