import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { deflateRawSync, gzipSync } from 'node:zlib';
import {
  validateArchiveEntries,
  validateTarGzArchive,
  validateZipArchive
} from './terminal-archive-policy.mjs';

function crc32(buffer) {
  let value = 0xffffffff;
  for (const byte of buffer) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit += 1) value = (value >>> 1) ^ (0xedb88320 & -(value & 1));
  }
  return (value ^ 0xffffffff) >>> 0;
}

function zipFixture(entries) {
  const locals = [];
  const central = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.path, 'utf8');
    const extra = entry.extra ?? Buffer.alloc(0);
    const data = Buffer.from(entry.type === 'symlink' ? entry.target : (entry.data ?? ''), 'utf8');
    const method = data.length === 0 ? 0 : 8;
    const compressed = method === 0 ? data : deflateRawSync(data);
    const checksum = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(extra.length, 28);
    locals.push(local, name, extra, compressed);

    const mode = entry.mode ?? ({ directory: 0o040755, file: 0o100644, symlink: 0o120777 }[entry.type]);
    const header = Buffer.alloc(46);
    header.writeUInt32LE(0x02014b50, 0);
    header.writeUInt16LE((3 << 8) | 20, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt16LE(0x0800, 8);
    header.writeUInt16LE(method, 10);
    header.writeUInt32LE(checksum, 16);
    header.writeUInt32LE(compressed.length, 20);
    header.writeUInt32LE(data.length, 24);
    header.writeUInt16LE(name.length, 28);
    header.writeUInt16LE(extra.length, 30);
    header.writeUInt32LE((mode << 16) >>> 0, 38);
    header.writeUInt32LE(offset, 42);
    central.push(header, name, extra);
    offset += local.length + name.length + extra.length + compressed.length;
  }
  const centralBytes = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, centralBytes, end]);
}

function tarField(header, offset, length, value) {
  const bytes = Buffer.from(value, 'utf8');
  bytes.copy(header, offset, 0, Math.min(bytes.length, length));
}

function tarOctal(header, offset, length, value) {
  tarField(header, offset, length, value.toString(8).padStart(length - 1, '0') + '\0');
}

function tarFixture(entries) {
  const chunks = [];
  for (const entry of entries) {
    const data = Buffer.from(entry.data ?? '', 'utf8');
    const header = Buffer.alloc(512);
    tarField(header, 0, 100, entry.path);
    tarOctal(header, 100, 8, entry.type === 'directory' ? 0o755 : 0o644);
    tarOctal(header, 108, 8, 0);
    tarOctal(header, 116, 8, 0);
    tarOctal(header, 124, 12, data.length);
    tarOctal(header, 136, 12, 0);
    header.fill(0x20, 148, 156);
    header[156] = (entry.typeFlag ?? ({ file: '0', directory: '5', symlink: '2' }[entry.type])).charCodeAt(0);
    if (entry.target) tarField(header, 157, 100, entry.target);
    tarField(header, 257, 6, 'ustar\0');
    tarField(header, 263, 2, '00');
    let checksum = 0;
    for (const byte of header) checksum += byte;
    tarField(header, 148, 8, checksum.toString(8).padStart(6, '0') + '\0 ');
    chunks.push(header, data, Buffer.alloc((512 - (data.length % 512)) % 512));
  }
  chunks.push(Buffer.alloc(1024));
  return gzipSync(Buffer.concat(chunks));
}

function paxRecord(key, value) {
  const body = Buffer.from(`${key}=${value}\n`, 'utf8');
  let length = body.length + 2;
  while (true) {
    const prefix = Buffer.from(`${length} `, 'ascii');
    const nextLength = prefix.length + body.length;
    if (nextLength === length) return Buffer.concat([prefix, body]);
    length = nextLength;
  }
}

const safeRecords = [
  { path: 'Fixture.app/', type: 'directory' },
  { path: 'Fixture.app/Versions/', type: 'directory' },
  { path: 'Fixture.app/Versions/A/', type: 'directory' },
  { path: 'Fixture.app/Versions/A/value', type: 'file' },
  { path: 'Fixture.app/Versions/Current', type: 'symlink', target: 'A' }
];
assert.deepEqual(validateArchiveEntries(['Fixture.app/', 'Fixture.app/value'], 'Fixture.app'),
  ['Fixture.app', 'Fixture.app/value']);
assert.equal(validateArchiveEntries(safeRecords, 'Fixture.app').at(-1).target, 'A');
assert.throws(() => validateArchiveEntries(safeRecords, 'Fixture.app', 'fixture', { allowSymlinks: false }),
  /forbidden symlink/);
for (const entries of [
  ['Fixture.app/', '../escape'],
  ['Fixture.app/', '/absolute'],
  ['Fixture.app/', 'Fixture.app\\escape'],
  ['Fixture.app/', 'Foreign.app/value'],
  ['Fixture.app/', 'Fixture.app/__MACOSX/._value'],
  ['Fixture.app/', 'Fixture.app/._value'],
  ['Fixture.app/', 'Fixture.app/value', 'Fixture.app/value/'],
  ['Fixture.app/', 'Fixture.app//value'],
  ['Fixture.app/', 'Fixture.app/Value', 'Fixture.app/value'],
  ['Fixture.app/', 'Fixture.app/Caf\u00e9', 'Fixture.app/Cafe\u0301']
]) assert.throws(() => validateArchiveEntries(entries, 'Fixture.app'));
for (const record of [
  { path: 'Fixture.app/link', type: 'symlink', target: '/tmp' },
  { path: 'Fixture.app/link', type: 'symlink', target: '../../tmp' },
  { path: 'Fixture.app/device', type: 'character-device' },
  { path: 'Fixture.app/fifo', type: 'fifo' },
  { path: 'Fixture.app/hard', type: 'hardlink' }
]) {
  assert.throws(() => validateArchiveEntries([
    { path: 'Fixture.app/', type: 'directory' }, record
  ], 'Fixture.app'));
}
assert.throws(() => validateArchiveEntries([
  { path: 'Fixture.app/', type: 'directory' },
  { path: 'Fixture.app/link', type: 'symlink', target: 'target' },
  { path: 'Fixture.app/link/child', type: 'file' }
], 'Fixture.app'), /descendant beneath a symlink/);
assert.throws(() => validateArchiveEntries([
  { path: 'Fixture.app', type: 'symlink', target: 'Fixture.app' }
], 'Fixture.app'), /root is not a directory/);

const testDirectory = await mkdtemp(path.join(os.tmpdir(), 'peekaboo-terminal-archive-policy.'));
try {
  const safeZip = path.join(testDirectory, 'safe.zip');
  await writeFile(safeZip, zipFixture([
    { path: 'Fixture.app/', type: 'directory' },
    { path: 'Fixture.app/Contents/', type: 'directory' },
    { path: 'Fixture.app/Contents/value', type: 'file', data: 'value' },
    { path: 'Fixture.app/Contents/current', type: 'symlink', target: 'value' }
  ]));
  assert.equal((await validateZipArchive(safeZip, 'Fixture.app')).at(-1).target, 'value');
  await assert.rejects(validateZipArchive(safeZip, 'Fixture.app', 'CLI ZIP', { allowSymlinks: false }),
    /forbidden symlink/);

  for (const [name, entries, pattern] of [
    ['escaping.zip', [
      { path: 'Fixture.app/', type: 'directory' },
      { path: 'Fixture.app/escape', type: 'symlink', target: '/tmp' }
    ], /unsafe symlink target/],
    ['fifo.zip', [
      { path: 'Fixture.app/', type: 'directory' },
      { path: 'Fixture.app/fifo', type: 'file', mode: 0o010644 }
    ], /forbidden fifo/],
    ['collision.zip', [
      { path: 'Fixture.app/', type: 'directory' },
      { path: 'Fixture.app/Value', type: 'file' },
      { path: 'Fixture.app/value', type: 'file' }
    ], /collision/],
    ['below-link.zip', [
      { path: 'Fixture.app/', type: 'directory' },
      { path: 'Fixture.app/link', type: 'symlink', target: 'target' },
      { path: 'Fixture.app/link/child', type: 'file' }
    ], /descendant beneath a symlink/]
  ]) {
    const fixture = path.join(testDirectory, name);
    await writeFile(fixture, zipFixture(entries));
    await assert.rejects(validateZipArchive(fixture, 'Fixture.app'), pattern);
  }
  const conflictingLocalZip = path.join(testDirectory, 'conflicting-local.zip');
  const conflictingBytes = zipFixture([{ path: 'Fixture.app/', type: 'directory' }]);
  Buffer.from('Foreign.app/', 'utf8').copy(conflictingBytes, 30);
  await writeFile(conflictingLocalZip, conflictingBytes);
  await assert.rejects(validateZipArchive(conflictingLocalZip, 'Fixture.app'), /conflicting local path metadata/);
  const alternateMetadataZip = path.join(testDirectory, 'alternate-metadata.zip');
  const asiUnixExtra = Buffer.from([0x6e, 0x75, 0x00, 0x00]);
  await writeFile(alternateMetadataZip, zipFixture([
    { path: 'Fixture.app/', type: 'directory' },
    { path: 'Fixture.app/value', type: 'file', data: 'value', extra: asiUnixExtra }
  ]));
  await assert.rejects(validateZipArchive(alternateMetadataZip, 'Fixture.app'), /unsupported ZIP extra field/);
  const zipBomb = path.join(testDirectory, 'zip-bomb.zip');
  const zipBombBytes = zipFixture([
    { path: 'Fixture.app/', type: 'directory' },
    { path: 'Fixture.app/value', type: 'file', data: 'small' }
  ]);
  const zipBombCentral = zipBombBytes.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  zipBombBytes.writeUInt32LE(600 * 1024 * 1024, zipBombCentral + 24);
  await writeFile(zipBomb, zipBombBytes);
  await assert.rejects(validateZipArchive(zipBomb, 'Fixture.app'), /uncompressed ZIP size limit/);

  const safeTar = path.join(testDirectory, 'safe.tar.gz');
  await writeFile(safeTar, tarFixture([
    { path: 'fixture/', type: 'directory' },
    { path: 'fixture/value', type: 'file', data: 'value' },
    { path: 'fixture/current', type: 'symlink', target: 'value' }
  ]));
  assert.equal((await validateTarGzArchive(safeTar, 'fixture')).at(-1).target, 'value');
  await assert.rejects(validateTarGzArchive(safeTar, 'fixture', 'CLI tar', { allowSymlinks: false }),
    /forbidden symlink/);

  for (const [name, entry, pattern] of [
    ['hardlink.tar.gz', { path: 'fixture/hard', typeFlag: '1', target: 'fixture/value' }, /forbidden hardlink/],
    ['fifo.tar.gz', { path: 'fixture/fifo', typeFlag: '6' }, /forbidden fifo/],
    ['escape.tar.gz', { path: 'fixture/escape', type: 'symlink', target: '../../tmp' }, /escaping symlink/]
  ]) {
    const fixture = path.join(testDirectory, name);
    await writeFile(fixture, tarFixture([{ path: 'fixture/', type: 'directory' }, entry]));
    await assert.rejects(validateTarGzArchive(fixture, 'fixture'), pattern);
  }
  for (const [name, entries, pattern] of [
    ['below-link.tar.gz', [
      { path: 'fixture/', type: 'directory' },
      { path: 'fixture/link', type: 'symlink', target: 'target' },
      { path: 'fixture/link/child', type: 'file' }
    ], /descendant beneath a symlink/],
    ['pax-escape.tar.gz', [
      { path: 'fixture/', type: 'directory' },
      { path: 'PaxHeader', typeFlag: 'x', data: paxRecord('path', '../escape') },
      { path: 'fixture/value', type: 'file' }
    ], /unsafe, foreign-root/],
    ['pax-xattr.tar.gz', [
      { path: 'fixture/', type: 'directory' },
      { path: 'PaxHeader', typeFlag: 'x', data: paxRecord('SCHILY.xattr.com.apple.FinderInfo', 'value') },
      { path: 'fixture/value', type: 'file' }
    ], /forbidden PAX metadata/]
  ]) {
    const fixture = path.join(testDirectory, name);
    await writeFile(fixture, tarFixture(entries));
    await assert.rejects(validateTarGzArchive(fixture, 'fixture'), pattern);
  }
} finally {
  await rm(testDirectory, { recursive: true, force: true });
}

process.stdout.write('test-terminal-archive-policy: ok\n');
