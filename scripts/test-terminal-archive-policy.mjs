import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { deflateRawSync, gunzipSync, gzipSync } from 'node:zlib';
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
    const compressed = Buffer.concat([method === 0 ? data : deflateRawSync(data), entry.trailingCompressedBytes ?? Buffer.alloc(0)]);
    const checksum = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(entry.flags ?? 0x0800, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(extra.length, 28);
    const descriptor = entry.descriptor ?? Buffer.alloc(0);
    locals.push(local, name, extra, compressed, descriptor);

    const mode = entry.mode ?? ({ directory: 0o040755, file: 0o100644, symlink: 0o120777 }[entry.type]);
    const header = Buffer.alloc(46);
    header.writeUInt32LE(0x02014b50, 0);
    header.writeUInt16LE((3 << 8) | 20, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt16LE(entry.flags ?? 0x0800, 8);
    header.writeUInt16LE(method, 10);
    header.writeUInt32LE(checksum, 16);
    header.writeUInt32LE(compressed.length, 20);
    header.writeUInt32LE(data.length, 24);
    header.writeUInt16LE(name.length, 28);
    header.writeUInt16LE(extra.length, 30);
    header.writeUInt32LE((mode << 16) >>> 0, 38);
    header.writeUInt32LE(offset, 42);
    central.push(header, name, extra);
    offset += local.length + name.length + extra.length + compressed.length + descriptor.length;
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

function tarChecksum(header) {
  header.fill(0x20, 148, 156);
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  tarField(header, 148, 8, checksum.toString(8).padStart(6, '0') + '\0 ');
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
    tarChecksum(header);
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

const legacyHierarchy = ['Fixture.app/', 'Fixture.app/value', 'Fixture.app/value/child'];
const normalizedHierarchy = ['Fixture.app', 'Fixture.app/value', 'Fixture.app/value/child'];
assert.deepEqual(validateArchiveEntries(legacyHierarchy, 'Fixture.app'), normalizedHierarchy);
assert.deepEqual(validateArchiveEntries(legacyHierarchy.map((entryPath) => ({ path: entryPath })), 'Fixture.app'),
  normalizedHierarchy.map((entryPath) => ({ path: entryPath, type: null, target: null })));

assert.throws(() => validateArchiveEntries([
  { path: 'Fixture.app/', type: 'directory' },
  { path: 'Fixture.app/alias', type: 'symlink', target: '.' },
  { path: 'Fixture.app/escape', type: 'symlink', target: 'alias/../outside' }
], 'Fixture.app'), /escaping symlink/);
assert.throws(() => validateArchiveEntries([
  { path: 'Fixture.app/', type: 'directory' },
  { path: 'Fixture.app/loop', type: 'symlink', target: 'loop' }
], 'Fixture.app'), /symlink expansion limit/);
assert.equal(validateArchiveEntries([
  { path: 'Fixture.app/', type: 'directory' },
  { path: 'Fixture.app/alias', type: 'symlink', target: '.' },
  { path: 'Fixture.app/current', type: 'symlink', target: 'alias/missing' }
], 'Fixture.app').length, 3);

assert.equal(validateArchiveEntries([
  ...safeRecords,
  { path: 'Fixture.app/current', type: 'symlink', target: 'Versions/Current/../A/value' },
  { path: 'Fixture.app/dangling', type: 'symlink', target: 'Versions/Current/missing' }
], 'Fixture.app').length, 7);

const testDirectory = await mkdtemp(path.join(os.tmpdir(), 'peekaboo-terminal-archive-policy.'));
try {
  const parentFileEntries = [
    { path: 'Fixture.app/', type: 'directory' },
    { path: 'Fixture.app/value', type: 'file', data: 'parent' },
    { path: 'Fixture.app/value/child', type: 'file', data: 'child' }
  ];
  for (const childFirst of [false, true]) {
    const orderedEntries = childFirst ?
      [parentFileEntries[0], parentFileEntries[2], parentFileEntries[1]] : parentFileEntries;
    assert.throws(() => validateArchiveEntries(orderedEntries, 'Fixture.app'), /descendant beneath a file/);
    const directoryEntries = orderedEntries.map((entry) => entry.path === 'Fixture.app/value' ?
      { path: 'Fixture.app/value/', type: 'directory' } : entry);
    const expectedDirectories = directoryEntries.map((entry) => ({
      path: entry.path.replace(/\/$/, ''), type: entry.type, target: null
    }));
    assert.deepEqual(validateArchiveEntries(directoryEntries, 'Fixture.app'), expectedDirectories);
    for (const [extension, encode, validate] of [
      ['zip', zipFixture, validateZipArchive],
      ['tar.gz', tarFixture, validateTarGzArchive]
    ]) {
      const archive = path.join(testDirectory, `file-parent-${childFirst}.${extension}`);
      await writeFile(archive, encode(orderedEntries));
      await assert.rejects(validate(archive, 'Fixture.app'), /descendant beneath a file/);
      const directoryArchive = path.join(testDirectory, `directory-parent-${childFirst}.${extension}`);
      await writeFile(directoryArchive, encode(directoryEntries));
      assert.deepEqual(await validate(directoryArchive, 'Fixture.app'), expectedDirectories);
    }
  }
  for (const count of [32, 33]) {
    const chain = [
      { path: 'Fixture.app/', type: 'directory' },
      { path: 'Fixture.app/value', type: 'file', data: 'boundary' },
      ...Array.from({ length: count }, (_, index) => ({
        path: `Fixture.app/link-${index}`, type: 'symlink',
        target: index + 1 === count ? 'value' : `link-${index + 1}`
      }))
    ];
    if (count === 32) assert.equal(validateArchiveEntries(chain, 'Fixture.app').length, count + 2);
    else assert.throws(() => validateArchiveEntries(chain, 'Fixture.app'), /symlink expansion limit/);
    for (const [extension, bytes, validate] of [
      ['zip', zipFixture(chain), validateZipArchive],
      ['tar.gz', tarFixture(chain), validateTarGzArchive]
    ]) {
      const archive = path.join(testDirectory, `chain-${count}.${extension}`);
      await writeFile(archive, bytes);
      if (count === 32) assert.equal((await validate(archive, 'Fixture.app')).length, count + 2);
      else await assert.rejects(validate(archive, 'Fixture.app'), /symlink expansion limit/);
    }
  }
  const composedEntries = [
    { path: 'Fixture.app/', type: 'directory' },
    { path: 'Fixture.app/alias', type: 'symlink', target: '.' },
    { path: 'Fixture.app/escape', type: 'symlink', target: 'alias/../outside' }
  ];
  for (const [extension, bytes, validate] of [
    ['zip', zipFixture(composedEntries), validateZipArchive],
    ['tar.gz', tarFixture(composedEntries), validateTarGzArchive]
  ]) {
    const archive = path.join(testDirectory, `composed.${extension}`);
    await writeFile(archive, bytes);
    await assert.rejects(validate(archive, 'Fixture.app'), /escaping symlink/);
  }
  // Archive links are always relative: noncanonical absolute spellings must
  // be refused before any composed containment resolution.
  for (const target of ['/tmp/./Fixture.app/alias/../outside', '/tmp/unused/../Fixture.app/value']) {
    const absoluteEntries = [
      { path: 'Fixture.app/', type: 'directory' },
      { path: 'Fixture.app/alias', type: 'symlink', target: '.' },
      { path: 'Fixture.app/absolute', type: 'symlink', target }
    ];
    for (const [extension, bytes, validate] of [
      ['zip', zipFixture(absoluteEntries), validateZipArchive],
      ['tar.gz', tarFixture(absoluteEntries), validateTarGzArchive]
    ]) {
      const archive = path.join(testDirectory, `absolute.${extension}`);
      await writeFile(archive, bytes);
      await assert.rejects(validate(archive, 'Fixture.app'), /unsafe symlink target/);
    }
  }
  for (const gap of [25, 16 * 1024 * 1024]) {
    const oversizedDescriptorZip = path.join(testDirectory, `oversized-descriptor-${gap}.zip`);
    await writeFile(oversizedDescriptorZip, zipFixture([
      { path: 'Fixture.app/', type: 'directory', flags: 0x0808, descriptor: Buffer.alloc(gap) }
    ]));
    const allocations = [];
    const originalAlloc = Buffer.alloc;
    Buffer.alloc = (size, ...arguments_) => {
      allocations.push(size);
      return originalAlloc(size, ...arguments_);
    };
    try {
      await assert.rejects(validateZipArchive(oversizedDescriptorZip, 'Fixture.app'), /invalid ZIP data descriptor/);
    } finally {
      Buffer.alloc = originalAlloc;
    }
    assert.ok(!allocations.includes(gap), `invalid ${gap}-byte descriptor must be refused before allocation`);
    assert.ok(allocations.every(size => size <= 1024 * 1024), 'no unbounded descriptor allocation');
  }
  for (const signed of [false, true]) {
    const data = Buffer.from('nonempty descriptor payload');
    const cursor = signed ? 4 : 0;
    const descriptor = Buffer.alloc(signed ? 16 : 12);
    if (signed) descriptor.writeUInt32LE(0x08074b50, 0);
    descriptor.writeUInt32LE(crc32(data), cursor);
    descriptor.writeUInt32LE(deflateRawSync(data).length, cursor + 4);
    descriptor.writeUInt32LE(data.length, cursor + 8);
    const validDescriptorZip = path.join(testDirectory, `descriptor-${signed}.zip`);
    await writeFile(validDescriptorZip, zipFixture([
      { path: 'Fixture.app/', type: 'directory' },
      { path: 'Fixture.app/value', type: 'file', data, flags: 0x0808, descriptor }
    ]));
    const records = await validateZipArchive(validDescriptorZip, 'Fixture.app');
    assert.equal(records.length, 2);
    assert.equal(records[1].path, 'Fixture.app/value');
    assert.equal(records[1].type, 'file');
  }
  const highBitTar = path.join(testDirectory, 'high-bit-octal.tar.gz');
  const rawTar = gunzipSync(tarFixture([{ path: 'Fixture.app/', type: 'directory' }]));
  rawTar[125] |= 0x80; // Not base-256: the first size byte remains an ASCII octal digit.
  tarChecksum(rawTar.subarray(0, 512));
  await writeFile(highBitTar, gzipSync(rawTar));
  await assert.rejects(validateTarGzArchive(highBitTar, 'Fixture.app'), /non-ASCII tar size/);

  const highBitChecksum = path.join(testDirectory, 'high-bit-checksum.tar.gz');
  const rawChecksum = gunzipSync(tarFixture([{ path: 'Fixture.app/', type: 'directory' }]));
  rawChecksum[149] |= 0x80; // Checksum bytes count as spaces; do not recompute after mutating them.
  await writeFile(highBitChecksum, gzipSync(rawChecksum));
  await assert.rejects(validateTarGzArchive(highBitChecksum, 'Fixture.app'), /non-ASCII tar checksum/);

  const highBitLength = path.join(testDirectory, 'high-bit-pax-length.tar.gz');
  const malformedLength = paxRecord('path', 'Fixture.app/value');
  malformedLength[0] |= 0x80;
  await writeFile(highBitLength, tarFixture([
    { path: 'Fixture.app/', type: 'directory' },
    { path: 'PaxHeader', typeFlag: 'x', data: malformedLength },
    { path: 'Fixture.app/value', type: 'file', data: 'value' }
  ]));
  await assert.rejects(validateTarGzArchive(highBitLength, 'Fixture.app'), /non-ASCII PAX record length/);

  const highBitPax = path.join(testDirectory, 'high-bit-pax.tar.gz');
  const malformedPax = paxRecord('path', 'Fixture.app/value');
  malformedPax[malformedPax.indexOf(Buffer.from('path')) + 1] |= 0x80;
  await writeFile(highBitPax, tarFixture([
    { path: 'Fixture.app/', type: 'directory' },
    { path: 'PaxHeader', typeFlag: 'x', data: malformedPax },
    { path: 'Fixture.app/value', type: 'file', data: 'value' }
  ]));
  await assert.rejects(validateTarGzArchive(highBitPax, 'Fixture.app'), /non-ASCII PAX key/);

  const binarySize = path.join(testDirectory, 'base256-size.tar.gz');
  const rawBinarySize = gunzipSync(tarFixture([
    { path: 'Fixture.app/', type: 'directory' },
    { path: 'Fixture.app/value', type: 'file', data: 'value' }
  ]));
  const binaryHeader = rawBinarySize.subarray(512, 1024);
  binaryHeader.fill(0, 124, 136);
  binaryHeader[124] = 0x80;
  binaryHeader[135] = 5;
  tarChecksum(binaryHeader);
  await writeFile(binarySize, gzipSync(rawBinarySize));
  assert.deepEqual(await validateTarGzArchive(binarySize, 'Fixture.app'), [
    { path: 'Fixture.app', type: 'directory', target: null },
    { path: 'Fixture.app/value', type: 'file', target: null }
  ]);

  const utf8Pax = path.join(testDirectory, 'utf8-pax-value.tar.gz');
  await writeFile(utf8Pax, tarFixture([
    { path: 'Fixture.app/', type: 'directory' },
    { path: 'PaxHeader', typeFlag: 'x', data: paxRecord('path', 'Fixture.app/café-東京') },
    { path: 'Fixture.app/value', type: 'file', data: 'value' }
  ]));
  assert.equal((await validateTarGzArchive(utf8Pax, 'Fixture.app'))[1].path, 'Fixture.app/café-東京');

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

  for (const [name, suffix] of [
    ['small', Buffer.from('unbound')],
    ['multi-chunk', Buffer.alloc(192 * 1024, 0x61)],
    ['second-stream', deflateRawSync(Buffer.from('second payload'))]
  ]) {
    const trailingZip = path.join(testDirectory, `trailing-deflate-${name}.zip`);
    await writeFile(trailingZip, zipFixture([
      { path: 'Fixture.app/', type: 'directory' },
      { path: 'Fixture.app/value', type: 'file', data: 'payload', trailingCompressedBytes: suffix }
    ]));
    if (name === 'multi-chunk') {
      // A caught validation error must not leave a reader using the closed archive
      // descriptor or emit a later uncaught inflater error in the caller's process.
      const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
        import assert from 'node:assert/strict';
        const { validateZipArchive } = await import(process.argv[1]);
        for (let attempt = 0; attempt < 4; attempt += 1) {
          await assert.rejects(validateZipArchive(process.argv[2], 'Fixture.app'),
            /unbound bytes after its DEFLATE stream/);
          assert.equal((await validateZipArchive(process.argv[3], 'Fixture.app')).length, 4);
        }
        await new Promise((resolve) => setTimeout(resolve, 50));
        console.log('PASS rejected payload cleanup and subsequent valid archives');
      `, new URL('./terminal-archive-policy.mjs', import.meta.url).href, trailingZip, safeZip],
      { encoding: 'utf8', timeout: 10000 });
      assert.equal(child.status, 0, child.stderr || String(child.error));
      assert.match(child.stdout, /PASS rejected payload cleanup/);
    }
    await assert.rejects(validateZipArchive(trailingZip, 'Fixture.app'), /unbound bytes after its DEFLATE stream/);
  }

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
