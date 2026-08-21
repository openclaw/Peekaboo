import { createReadStream } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import path from 'node:path';
import { createGunzip, createInflateRaw } from 'node:zlib';

const UTF8_DECODER = new TextDecoder('utf-8', { fatal: true });
const ZIP_EOCD_SIGNATURE = 0x06054b50;
const ZIP64_EOCD_SIGNATURE = 0x06064b50;
const ZIP64_LOCATOR_SIGNATURE = 0x07064b50;
const ZIP_CENTRAL_SIGNATURE = 0x02014b50;
const ZIP_LOCAL_SIGNATURE = 0x04034b50;
const ZIP_MAX_CENTRAL_DIRECTORY = 64 * 1024 * 1024;
const ZIP_MAX_SYMLINK_TARGET = 64 * 1024;
const ZIP_MAX_UNCOMPRESSED_SIZE = 512 * 1024 * 1024;
const ZIP_ALLOWED_EXTRA_FIELDS = new Set([0x0001, 0x5455, 0x5855, 0x7855, 0x7875]);
const TAR_MAX_UNCOMPRESSED_SIZE = 512 * 1024 * 1024;
const TAR_MAX_METADATA_SIZE = 1024 * 1024;
const MAX_ARCHIVE_ENTRIES = 100_000;

function fail(label, message) {
  throw new TypeError(`${label} ${message}`);
}

function archiveOptions(options) {
  const allowSymlinks = options?.allowSymlinks ?? true;
  if (typeof allowSymlinks !== 'boolean') throw new TypeError('allowSymlinks must be boolean');
  return { allowSymlinks };
}

function normalizedCollisionKey(value) {
  return value.normalize('NFKD').toUpperCase().toLowerCase().normalize('NFD');
}

function validateExpectedRoot(expectedRoot, label) {
  if (typeof expectedRoot !== 'string' || !expectedRoot || expectedRoot.includes('/') || expectedRoot.includes('\\') ||
      expectedRoot === '.' || expectedRoot === '..' || /[\0\r\n]/.test(expectedRoot)) {
    fail(label, 'expected root is invalid');
  }
}

function normalizedRecord(entry, label) {
  if (typeof entry === 'string') return { path: entry, type: null, target: null };
  if (!entry || typeof entry !== 'object' || Array.isArray(entry) || typeof entry.path !== 'string') {
    fail(label, 'has an invalid entry');
  }
  return {
    path: entry.path,
    type: typeof entry.type === 'string' ? entry.type : null,
    target: entry.target ?? null
  };
}

function validateSymlink(record, expectedRoot, label, allowSymlinks) {
  if (!allowSymlinks) fail(label, `contains a forbidden symlink: ${record.path}`);
  if (typeof record.target !== 'string' || !record.target || record.target.startsWith('/') ||
      record.target.includes('\\') || /[\0\r\n]/.test(record.target)) {
    fail(label, `contains an unsafe symlink target: ${record.path} -> ${String(record.target)}`);
  }
  const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(record.path), record.target));
  if (resolved !== expectedRoot && !resolved.startsWith(`${expectedRoot}/`)) {
    fail(label, `contains an escaping symlink: ${record.path} -> ${record.target}`);
  }
}

export function validateArchiveEntries(entries, expectedRoot, label = 'archive', options = {}) {
  validateExpectedRoot(expectedRoot, label);
  if (!Array.isArray(entries) || entries.length === 0) fail(label, 'entry contract is empty');
  if (entries.length > MAX_ARCHIVE_ENTRIES) fail(label, 'contains too many entries');
  const { allowSymlinks } = archiveOptions(options);
  const legacyNamesOnly = entries.every((entry) => typeof entry === 'string');
  const records = entries.map((entry) => normalizedRecord(entry, label));
  const exactPaths = new Set();
  const collisionPaths = new Map();
  const collisionPrefixes = new Map();
  const symlinks = new Set();
  let rootRecord = null;

  for (const record of records) {
    const entry = record.path;
    if (!entry || /[\0\r\n]/.test(entry)) fail(label, 'has an invalid entry');
    const withoutSlash = entry.endsWith('/') ? entry.slice(0, -1) : entry;
    const components = withoutSlash.split('/');
    if (/(^|\/)__MACOSX(\/|$)/.test(entry) || /(^|\/)\._[^/]+$/.test(entry) ||
        entry.startsWith('/') || entry.includes('\\') || components.includes('..') ||
        components.includes('.') || components.includes('') ||
        !(withoutSlash === expectedRoot || withoutSlash.startsWith(`${expectedRoot}/`))) {
      fail(label, `contains an unsafe, foreign-root, or AppleDouble entry: ${entry}`);
    }
    if (exactPaths.has(withoutSlash)) fail(label, `has duplicate entries: ${entry}`);
    exactPaths.add(withoutSlash);
    const collisionKey = normalizedCollisionKey(withoutSlash);
    const previous = collisionPaths.get(collisionKey);
    if (previous && previous !== withoutSlash) {
      fail(label, `has a case or Unicode-normalization collision: ${previous} / ${withoutSlash}`);
    }
    collisionPaths.set(collisionKey, withoutSlash);
    const pathComponents = withoutSlash.split('/');
    for (let length = 1; length <= pathComponents.length; length += 1) {
      const prefix = pathComponents.slice(0, length).join('/');
      const prefixKey = normalizedCollisionKey(prefix);
      const previousPrefix = collisionPrefixes.get(prefixKey);
      if (previousPrefix && previousPrefix !== prefix) {
        fail(label, `has a case or Unicode-normalization prefix collision: ${previousPrefix} / ${prefix}`);
      }
      collisionPrefixes.set(prefixKey, prefix);
    }
    record.path = withoutSlash;

    if (record.type !== null && !['file', 'directory', 'symlink'].includes(record.type)) {
      fail(label, `contains a forbidden ${record.type} entry: ${entry}`);
    }
    if (record.type === 'directory' && !entry.endsWith('/')) {
      fail(label, `contains a directory without a trailing slash: ${entry}`);
    }
    if (record.type !== null && record.type !== 'directory' && entry.endsWith('/')) {
      fail(label, `contains a non-directory with a trailing slash: ${entry}`);
    }
    if (record.type === 'symlink') {
      validateSymlink(record, expectedRoot, label, allowSymlinks);
      symlinks.add(normalizedCollisionKey(record.path));
    } else if (record.target !== null) {
      fail(label, `contains a link target on a non-symlink: ${entry}`);
    }
    if (withoutSlash === expectedRoot) rootRecord = record;
  }

  if (!rootRecord) fail(label, `does not contain its expected root: ${expectedRoot}`);
  if (rootRecord.type !== null && rootRecord.type !== 'directory') {
    fail(label, `root is not a directory: ${expectedRoot}`);
  }
  for (const record of records) {
    let ancestor = path.posix.dirname(record.path);
    while (ancestor !== '.' && ancestor !== '/') {
      if (symlinks.has(normalizedCollisionKey(ancestor))) {
        fail(label, `contains a descendant beneath a symlink: ${record.path}`);
      }
      if (ancestor === expectedRoot) break;
      ancestor = path.posix.dirname(ancestor);
    }
  }
  return legacyNamesOnly ? records.map((record) => record.path) : records;
}

async function requireRegularArchive(archivePath, label) {
  const metadata = await lstat(archivePath);
  if (!metadata.isFile() || metadata.isSymbolicLink()) fail(label, 'is not one regular archive file');
  return metadata.size;
}

function safeNumber(value, label, field) {
  if (typeof value === 'bigint') {
    if (value > BigInt(Number.MAX_SAFE_INTEGER)) fail(label, `${field} exceeds the safe integer range`);
    return Number(value);
  }
  if (!Number.isSafeInteger(value) || value < 0) fail(label, `${field} is invalid`);
  return value;
}

async function readExact(handle, position, length, label) {
  if (!Number.isSafeInteger(position) || position < 0 || !Number.isSafeInteger(length) || length < 0) {
    fail(label, 'contains an invalid byte range');
  }
  const buffer = Buffer.alloc(length);
  let offset = 0;
  while (offset < length) {
    const result = await handle.read(buffer, offset, length - offset, position + offset);
    if (result.bytesRead === 0) fail(label, 'is truncated');
    offset += result.bytesRead;
  }
  return buffer;
}

function zipExtraFields(extra, label) {
  const fields = [];
  const identifiers = new Set();
  let cursor = 0;
  while (cursor < extra.length) {
    if (cursor + 4 > extra.length) fail(label, 'contains a truncated ZIP extra field');
    const identifier = extra.readUInt16LE(cursor);
    const size = extra.readUInt16LE(cursor + 2);
    cursor += 4;
    if (cursor + size > extra.length) fail(label, 'contains a truncated ZIP extra field payload');
    if (identifiers.has(identifier)) fail(label, `contains duplicate ZIP extra field 0x${identifier.toString(16)}`);
    if (!ZIP_ALLOWED_EXTRA_FIELDS.has(identifier)) {
      // In particular, reject ASi Unix (0x756e), which can override regular-file metadata with a symlink target.
      fail(label, `contains unsupported ZIP extra field 0x${identifier.toString(16)}`);
    }
    identifiers.add(identifier);
    fields.push({ identifier, data: extra.subarray(cursor, cursor + size) });
    cursor += size;
  }
  return fields;
}

function crc32(buffer) {
  let value = 0xffffffff;
  value = crc32Update(value, buffer);
  return (value ^ 0xffffffff) >>> 0;
}

function crc32Update(value, buffer) {
  for (const byte of buffer) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit += 1) value = (value >>> 1) ^ (0xedb88320 & -(value & 1));
  }
  return value >>> 0;
}

function decodeZipPath(rawName, flags, extra, label) {
  let decoded;
  try {
    // ditto emits UTF-8 names but sets the data-descriptor bit rather than the optional language-encoding bit.
    // Requiring one unambiguous UTF-8 interpretation matches the producer and avoids CP437/Unicode disagreement.
    decoded = UTF8_DECODER.decode(rawName);
  } catch {
    fail(label, 'contains an invalid UTF-8 ZIP path');
  }

  zipExtraFields(extra, label);
  return decoded;
}

function zip64Values(extra, needs, label) {
  const fields = zipExtraFields(extra, label).filter((field) => field.identifier === 0x0001);
  if (fields.length !== 1) fail(label, 'is missing its ZIP64 metadata');
  const data = fields[0].data;
  let cursor = 0;
  const values = {};
  for (const [name, width] of needs) {
    if (cursor + width > data.length) fail(label, 'contains truncated ZIP64 metadata');
    values[name] = width === 8 ? safeNumber(data.readBigUInt64LE(cursor), label, name) : data.readUInt32LE(cursor);
    cursor += width;
  }
  return values;
}

function zipEntryType(unixMode, externalAttributes, entryPath) {
  const typeBits = unixMode & 0xf000;
  if (typeBits === 0x4000) return 'directory';
  if (typeBits === 0x8000) return 'file';
  if (typeBits === 0xa000) return 'symlink';
  if (typeBits === 0x1000) return 'fifo';
  if (typeBits === 0x2000) return 'character-device';
  if (typeBits === 0x6000) return 'block-device';
  if (typeBits === 0xc000) return 'socket';
  if (typeBits !== 0) return 'unknown';
  return entryPath.endsWith('/') || (externalAttributes & 0x10) !== 0 ? 'directory' : 'file';
}

async function zipDirectory(handle, fileSize, label) {
  const tailLength = Math.min(fileSize, 22 + 0xffff + 20 + 56);
  if (tailLength < 22) fail(label, 'is not a ZIP archive');
  const tailOffset = fileSize - tailLength;
  const tail = await readExact(handle, tailOffset, tailLength, label);
  let eocd = -1;
  for (let cursor = tail.length - 22; cursor >= 0; cursor -= 1) {
    if (tail.readUInt32LE(cursor) === ZIP_EOCD_SIGNATURE &&
        cursor + 22 + tail.readUInt16LE(cursor + 20) === tail.length) {
      eocd = cursor;
      break;
    }
  }
  if (eocd < 0) fail(label, 'has no valid ZIP end record');
  if (tail.readUInt16LE(eocd + 4) !== 0 || tail.readUInt16LE(eocd + 6) !== 0 ||
      tail.readUInt16LE(eocd + 8) !== tail.readUInt16LE(eocd + 10)) {
    fail(label, 'uses unsupported multi-disk ZIP storage');
  }
  let entryCount = tail.readUInt16LE(eocd + 10);
  let directorySize = tail.readUInt32LE(eocd + 12);
  let directoryOffset = tail.readUInt32LE(eocd + 16);
  if (entryCount === 0xffff || directorySize === 0xffffffff || directoryOffset === 0xffffffff) {
    if (eocd < 20 || tail.readUInt32LE(eocd - 20) !== ZIP64_LOCATOR_SIGNATURE ||
        tail.readUInt32LE(eocd - 16) !== 0 || tail.readUInt32LE(eocd - 4) !== 1) {
      fail(label, 'has invalid ZIP64 locator metadata');
    }
    const zip64Offset = safeNumber(tail.readBigUInt64LE(eocd - 12), label, 'ZIP64 end offset');
    const zip64 = await readExact(handle, zip64Offset, 56, label);
    if (zip64.readUInt32LE(0) !== ZIP64_EOCD_SIGNATURE || zip64.readBigUInt64LE(4) < 44n ||
        zip64.readUInt32LE(16) !== 0 || zip64.readUInt32LE(20) !== 0 ||
        zip64.readBigUInt64LE(24) !== zip64.readBigUInt64LE(32)) {
      fail(label, 'has invalid ZIP64 end metadata');
    }
    entryCount = safeNumber(zip64.readBigUInt64LE(32), label, 'ZIP entry count');
    directorySize = safeNumber(zip64.readBigUInt64LE(40), label, 'ZIP directory size');
    directoryOffset = safeNumber(zip64.readBigUInt64LE(48), label, 'ZIP directory offset');
  }
  if (entryCount === 0 || entryCount > MAX_ARCHIVE_ENTRIES) fail(label, 'has an invalid ZIP entry count');
  if (directorySize > ZIP_MAX_CENTRAL_DIRECTORY || directoryOffset + directorySize > fileSize) {
    fail(label, 'has an invalid ZIP central directory range');
  }
  return { entryCount, directoryOffset, directorySize };
}

function parseZipCentralDirectory(buffer, entryCount, label) {
  const records = [];
  let cursor = 0;
  for (let index = 0; index < entryCount; index += 1) {
    if (cursor + 46 > buffer.length || buffer.readUInt32LE(cursor) !== ZIP_CENTRAL_SIGNATURE) {
      fail(label, 'contains a malformed ZIP central directory');
    }
    const flags = buffer.readUInt16LE(cursor + 8);
    const method = buffer.readUInt16LE(cursor + 10);
    const checksum = buffer.readUInt32LE(cursor + 16);
    let compressedSize = buffer.readUInt32LE(cursor + 20);
    let uncompressedSize = buffer.readUInt32LE(cursor + 24);
    const nameLength = buffer.readUInt16LE(cursor + 28);
    const extraLength = buffer.readUInt16LE(cursor + 30);
    const commentLength = buffer.readUInt16LE(cursor + 32);
    let diskStart = buffer.readUInt16LE(cursor + 34);
    const externalAttributes = buffer.readUInt32LE(cursor + 38);
    let localOffset = buffer.readUInt32LE(cursor + 42);
    const end = cursor + 46 + nameLength + extraLength + commentLength;
    if (end > buffer.length) fail(label, 'contains a truncated ZIP central entry');
    const rawName = buffer.subarray(cursor + 46, cursor + 46 + nameLength);
    const extra = buffer.subarray(cursor + 46 + nameLength, cursor + 46 + nameLength + extraLength);
    const needs = [];
    if (uncompressedSize === 0xffffffff) needs.push(['uncompressedSize', 8]);
    if (compressedSize === 0xffffffff) needs.push(['compressedSize', 8]);
    if (localOffset === 0xffffffff) needs.push(['localOffset', 8]);
    if (diskStart === 0xffff) needs.push(['diskStart', 4]);
    if (needs.length > 0) {
      const zip64 = zip64Values(extra, needs, label);
      uncompressedSize = zip64.uncompressedSize ?? uncompressedSize;
      compressedSize = zip64.compressedSize ?? compressedSize;
      localOffset = zip64.localOffset ?? localOffset;
      diskStart = zip64.diskStart ?? diskStart;
    }
    if (diskStart !== 0) fail(label, 'contains a cross-disk ZIP entry');
    if ((flags & ~0x080e) !== 0 || (method !== 8 && (flags & 0x0006) !== 0)) {
      fail(label, 'contains encrypted or unsupported ZIP entry flags');
    }
    if (![0, 8].includes(method)) fail(label, `uses unsupported ZIP compression method ${method}`);
    const entryPath = decodeZipPath(rawName, flags, extra, label);
    const unixMode = externalAttributes >>> 16;
    records.push({
      path: entryPath, type: zipEntryType(unixMode, externalAttributes, entryPath), target: null,
      flags, method, checksum, compressedSize, uncompressedSize, localOffset, rawName
    });
    cursor = end;
  }
  if (cursor !== buffer.length) fail(label, 'contains unparsed ZIP central directory data');
  return records;
}

async function validateZipPayload(handle, dataOffset, record, budget, label) {
  if (record.compressedSize === 0) {
    if (record.uncompressedSize !== 0 || record.checksum !== 0) fail(label, `has a corrupt empty entry: ${record.path}`);
    return Buffer.alloc(0);
  }
  const source = createReadStream(null, {
    fd: handle.fd,
    start: dataOffset,
    end: dataOffset + record.compressedSize - 1,
    autoClose: false,
    emitClose: false
  });
  const inflater = record.method === 8 ? createInflateRaw() : null;
  source.on('error', (error) => inflater?.destroy(error));
  if (inflater) source.pipe(inflater);
  const output = inflater ?? source;
  const capture = record.type === 'symlink' ? [] : null;
  let outputSize = 0;
  let checksum = 0xffffffff;
  try {
    for await (const chunk of output) {
      if (chunk.length > record.uncompressedSize - outputSize) {
        fail(label, `expands beyond its declared size: ${record.path}`);
      }
      if (chunk.length > budget.maximum - budget.total) {
        fail(label, 'exceeds the uncompressed ZIP size limit');
      }
      outputSize += chunk.length;
      budget.total += chunk.length;
      checksum = crc32Update(checksum, chunk);
      if (capture) capture.push(chunk);
    }
  } catch (error) {
    if (error instanceof TypeError) throw error;
    fail(label, `has an invalid compressed payload: ${record.path}`);
  }
  if (outputSize !== record.uncompressedSize || ((checksum ^ 0xffffffff) >>> 0) !== record.checksum) {
    fail(label, `has a payload size or CRC mismatch: ${record.path}`);
  }
  return capture ? Buffer.concat(capture, outputSize) : null;
}

function validateZipDescriptor(descriptor, record, label) {
  let cursor = 0;
  if (descriptor.length >= 4 && descriptor.readUInt32LE(0) === 0x08074b50) cursor += 4;
  const zip64 = record.compressedSize > 0xffffffff || record.uncompressedSize > 0xffffffff;
  const expectedLength = cursor + 4 + (zip64 ? 16 : 8);
  if (descriptor.length !== expectedLength || descriptor.readUInt32LE(cursor) !== record.checksum) {
    fail(label, `has an invalid ZIP data descriptor: ${record.path}`);
  }
  cursor += 4;
  const compressedSize = zip64 ? safeNumber(descriptor.readBigUInt64LE(cursor), label, 'descriptor size') :
    descriptor.readUInt32LE(cursor);
  cursor += zip64 ? 8 : 4;
  const uncompressedSize = zip64 ? safeNumber(descriptor.readBigUInt64LE(cursor), label, 'descriptor size') :
    descriptor.readUInt32LE(cursor);
  if (compressedSize !== record.compressedSize || uncompressedSize !== record.uncompressedSize) {
    fail(label, `has conflicting ZIP data descriptor sizes: ${record.path}`);
  }
}

async function validateZipLocalEntries(handle, fileSize, directoryOffset, records, label, maximumSize) {
  const occupied = [];
  const budget = { total: 0, maximum: maximumSize };
  for (const record of records) {
    if (record.localOffset + 30 > directoryOffset) fail(label, `has an invalid local entry: ${record.path}`);
    const header = await readExact(handle, record.localOffset, 30, label);
    if (header.readUInt32LE(0) !== ZIP_LOCAL_SIGNATURE || header.readUInt16LE(6) !== record.flags ||
        header.readUInt16LE(8) !== record.method) {
      fail(label, `has conflicting local metadata: ${record.path}`);
    }
    const nameLength = header.readUInt16LE(26);
    const extraLength = header.readUInt16LE(28);
    const localName = await readExact(handle, record.localOffset + 30, nameLength, label);
    if (!localName.equals(record.rawName)) fail(label, `has conflicting local path metadata: ${record.path}`);
    const localExtra = await readExact(handle, record.localOffset + 30 + nameLength, extraLength, label);
    if (decodeZipPath(localName, record.flags, localExtra, label) !== record.path) {
      fail(label, `has conflicting local path encoding: ${record.path}`);
    }
    const dataOffset = record.localOffset + 30 + nameLength + extraLength;
    const dataEnd = dataOffset + record.compressedSize;
    if (!Number.isSafeInteger(dataEnd) || dataEnd > directoryOffset || dataEnd > fileSize) {
      fail(label, `has an invalid compressed data range: ${record.path}`);
    }
    if ((record.flags & 0x0008) === 0) {
      const localChecksum = header.readUInt32LE(14);
      let localCompressedSize = header.readUInt32LE(18);
      let localUncompressedSize = header.readUInt32LE(22);
      const needs = [];
      if (localUncompressedSize === 0xffffffff) needs.push(['uncompressedSize', 8]);
      if (localCompressedSize === 0xffffffff) needs.push(['compressedSize', 8]);
      if (needs.length > 0) {
        const zip64 = zip64Values(localExtra, needs, label);
        localUncompressedSize = zip64.uncompressedSize ?? localUncompressedSize;
        localCompressedSize = zip64.compressedSize ?? localCompressedSize;
      }
      if (localChecksum !== record.checksum || localCompressedSize !== record.compressedSize ||
          localUncompressedSize !== record.uncompressedSize) {
        fail(label, `has conflicting local size or CRC metadata: ${record.path}`);
      }
    }
    occupied.push({ start: record.localOffset, end: dataEnd, path: record.path, record });
    if (record.type === 'symlink') {
      if (record.uncompressedSize === 0 || record.uncompressedSize > ZIP_MAX_SYMLINK_TARGET ||
          record.compressedSize > ZIP_MAX_SYMLINK_TARGET) {
        fail(label, `has an invalid symlink payload size: ${record.path}`);
      }
    }
    const targetBytes = await validateZipPayload(handle, dataOffset, record, budget, label);
    if (record.type === 'symlink') {
      try {
        record.target = UTF8_DECODER.decode(targetBytes);
      } catch {
        fail(label, `has a non-UTF-8 symlink target: ${record.path}`);
      }
    }
  }
  occupied.sort((left, right) => left.start - right.start);
  if (occupied[0]?.start !== 0) fail(label, 'contains an unbound ZIP preamble');
  for (let index = 0; index < occupied.length; index += 1) {
    const current = occupied[index];
    const nextOffset = occupied[index + 1]?.start ?? directoryOffset;
    if (nextOffset < current.end) {
      fail(label, `contains overlapping ZIP entries: ${current.path} / ${occupied[index + 1]?.path ?? 'central'}`);
    }
    const gap = nextOffset - current.end;
    if ((current.record.flags & 0x0008) !== 0) {
      const descriptor = await readExact(handle, current.end, gap, label);
      validateZipDescriptor(descriptor, current.record, label);
    } else if (gap !== 0) {
      fail(label, `contains unbound data between ZIP entries: ${current.path}`);
    }
  }
}

export async function validateZipArchive(archivePath, expectedRoot, label = 'ZIP archive', options = {}) {
  const fileSize = await requireRegularArchive(archivePath, label);
  const maxUncompressedSize = options.maxUncompressedSize ?? ZIP_MAX_UNCOMPRESSED_SIZE;
  if (!Number.isSafeInteger(maxUncompressedSize) || maxUncompressedSize <= 0) {
    throw new TypeError('maxUncompressedSize must be a positive safe integer');
  }
  const handle = await open(archivePath, 'r');
  try {
    const directory = await zipDirectory(handle, fileSize, label);
    const bytes = await readExact(handle, directory.directoryOffset, directory.directorySize, label);
    const records = parseZipCentralDirectory(bytes, directory.entryCount, label);
    let totalUncompressedSize = 0;
    for (const record of records) {
      if (record.uncompressedSize > maxUncompressedSize - totalUncompressedSize) {
        fail(label, 'exceeds the uncompressed ZIP size limit');
      }
      totalUncompressedSize += record.uncompressedSize;
    }
    await validateZipLocalEntries(handle, fileSize, directory.directoryOffset, records, label, maxUncompressedSize);
    return validateArchiveEntries(records, expectedRoot, label, options);
  } finally {
    await handle.close();
  }
}

function tarString(bytes, label, field) {
  const end = bytes.indexOf(0);
  if (end >= 0 && bytes.subarray(end + 1).some((byte) => byte !== 0)) {
    fail(label, `contains ambiguous tar ${field} padding`);
  }
  const value = end >= 0 ? bytes.subarray(0, end) : bytes;
  try {
    return UTF8_DECODER.decode(value);
  } catch {
    fail(label, `contains a non-UTF-8 tar ${field}`);
  }
}

function tarNumber(bytes, label, field) {
  if ((bytes[0] & 0x80) !== 0) {
    if ((bytes[0] & 0x40) !== 0) fail(label, `contains a negative tar ${field}`);
    let value = BigInt(bytes[0] & 0x3f);
    for (const byte of bytes.subarray(1)) value = (value << 8n) | BigInt(byte);
    return safeNumber(value, label, `tar ${field}`);
  }
  const text = bytes.toString('ascii').replace(/\0.*$/s, '').trim();
  if (!text) return 0;
  if (!/^[0-7]+$/.test(text)) fail(label, `contains an invalid tar ${field}`);
  return safeNumber(Number.parseInt(text, 8), label, `tar ${field}`);
}

function validateTarChecksum(header, label) {
  const expected = tarNumber(header.subarray(148, 156), label, 'checksum');
  let unsigned = 0;
  let signed = 0;
  for (let index = 0; index < header.length; index += 1) {
    const byte = index >= 148 && index < 156 ? 0x20 : header[index];
    unsigned += byte;
    signed += byte > 127 ? byte - 256 : byte;
  }
  if (expected !== unsigned && expected !== signed) fail(label, 'contains a tar header checksum mismatch');
}

function parseTarHeader(header, label) {
  validateTarChecksum(header, label);
  if (!header.subarray(257, 263).equals(Buffer.from('ustar\0')) ||
      !header.subarray(263, 265).equals(Buffer.from('00'))) {
    fail(label, 'contains a non-USTAR header');
  }
  const name = tarString(header.subarray(0, 100), label, 'path');
  const prefix = tarString(header.subarray(345, 500), label, 'prefix');
  const entryPath = prefix ? `${prefix}/${name}` : name;
  if (!entryPath) fail(label, 'contains an empty tar path');
  return {
    path: entryPath,
    size: tarNumber(header.subarray(124, 136), label, 'size'),
    typeFlag: header[156] === 0 ? '0' : String.fromCharCode(header[156]),
    target: tarString(header.subarray(157, 257), label, 'link target')
  };
}

function parsePaxRecords(bytes, label) {
  const records = {};
  let cursor = 0;
  while (cursor < bytes.length) {
    const space = bytes.indexOf(0x20, cursor);
    if (space < 0) fail(label, 'contains malformed PAX metadata');
    const lengthText = bytes.subarray(cursor, space).toString('ascii');
    if (!/^[1-9][0-9]*$/.test(lengthText)) fail(label, 'contains malformed PAX record length');
    const length = Number.parseInt(lengthText, 10);
    if (!Number.isSafeInteger(length) || length <= space - cursor + 2 || cursor + length > bytes.length ||
        bytes[cursor + length - 1] !== 0x0a) {
      fail(label, 'contains an invalid PAX record range');
    }
    const payload = bytes.subarray(space + 1, cursor + length - 1);
    const equals = payload.indexOf(0x3d);
    if (equals <= 0) fail(label, 'contains malformed PAX metadata');
    const key = payload.subarray(0, equals).toString('ascii');
    if (!/^[A-Za-z0-9_.-]+$/.test(key) || Object.hasOwn(records, key)) {
      fail(label, 'contains an invalid or duplicate PAX key');
    }
    let value;
    try {
      value = UTF8_DECODER.decode(payload.subarray(equals + 1));
    } catch {
      fail(label, `contains non-UTF-8 PAX metadata: ${key}`);
    }
    const securityKey = key.toLowerCase();
    if (securityKey.includes('xattr') || securityKey.includes('acl') || securityKey.includes('sparse') ||
        securityKey.includes('devmajor') || securityKey.includes('devminor')) {
      fail(label, `contains forbidden PAX metadata: ${key}`);
    }
    const allowed = ['path', 'linkpath', 'size', 'mtime', 'atime', 'ctime', 'birthtime', 'uid', 'gid',
      'uname', 'gname', 'comment', 'charset', 'hdrcharset'];
    if (!allowed.includes(key) && !/^LIBARCHIVE\.(creationtime|mtime|atime|ctime)$/.test(key)) {
      fail(label, `contains unsupported PAX metadata: ${key}`);
    }
    records[key] = value;
    cursor += length;
  }
  return records;
}

function paxSize(value, fallback, label) {
  if (value === undefined) return fallback;
  if (!/^(0|[1-9][0-9]*)$/.test(value)) fail(label, 'contains an invalid PAX size');
  return safeNumber(Number(value), label, 'PAX size');
}

function tarRecord(header, attributes, longPath, longLink, label) {
  if (longPath && attributes.path) fail(label, 'contains conflicting tar path overrides');
  if (longLink && attributes.linkpath) fail(label, 'contains conflicting tar link overrides');
  const entryPath = attributes.path ?? longPath ?? header.path;
  const target = attributes.linkpath ?? longLink ?? header.target;
  const size = paxSize(attributes.size, header.size, label);
  let type;
  switch (header.typeFlag) {
    case '0': type = 'file'; break;
    case '5': type = 'directory'; break;
    case '2': type = 'symlink'; break;
    case '1': type = 'hardlink'; break;
    case '3': type = 'character-device'; break;
    case '4': type = 'block-device'; break;
    case '6': type = 'fifo'; break;
    default: type = `unsupported-tar-type-${header.typeFlag}`;
  }
  if ((type === 'directory' || type === 'symlink' || type === 'hardlink') && size !== 0) {
    fail(label, `contains a non-empty tar ${type}: ${entryPath}`);
  }
  return { record: { path: entryPath, type, target: type === 'symlink' ? target : null }, size };
}

function metadataText(bytes, label, kind) {
  if (bytes.length === 0 || bytes.length > TAR_MAX_METADATA_SIZE) fail(label, `has invalid ${kind} metadata size`);
  const nul = bytes.indexOf(0);
  let text;
  try {
    text = UTF8_DECODER.decode(bytes.subarray(0, nul >= 0 ? nul : bytes.length));
  } catch {
    fail(label, `has non-UTF-8 ${kind} metadata`);
  }
  const trimmed = text.replace(/\n$/, '');
  if (!trimmed) fail(label, `has empty ${kind} metadata`);
  return trimmed;
}

async function parseTarGz(archivePath, label, maxUncompressedSize) {
  const input = createReadStream(archivePath);
  const gunzip = createGunzip();
  input.on('error', (error) => gunzip.destroy(error));
  input.pipe(gunzip);
  const records = [];
  let buffer = Buffer.alloc(0);
  let current = null;
  let totalSize = 0;
  let zeroBlocks = 0;
  let ended = false;
  let globalPax = {};
  let pendingPax = null;
  let pendingLongPath = null;
  let pendingLongLink = null;

  const finishMetadata = (metadata) => {
    const bytes = Buffer.concat(metadata.chunks, metadata.dataSize);
    if (metadata.kind === 'x') {
      if (pendingPax) fail(label, 'contains stacked per-file PAX metadata');
      pendingPax = parsePaxRecords(bytes, label);
    } else if (metadata.kind === 'g') {
      const parsed = parsePaxRecords(bytes, label);
      if (parsed.path !== undefined || parsed.linkpath !== undefined || parsed.size !== undefined) {
        fail(label, 'contains path or size in global PAX metadata');
      }
      globalPax = { ...globalPax, ...parsed };
    } else if (metadata.kind === 'L') {
      if (pendingLongPath) fail(label, 'contains stacked GNU long paths');
      pendingLongPath = metadataText(bytes, label, 'GNU long path');
    } else if (metadata.kind === 'K') {
      if (pendingLongLink) fail(label, 'contains stacked GNU long links');
      pendingLongLink = metadataText(bytes, label, 'GNU long link');
    }
  };

  for await (const chunk of gunzip) {
    totalSize += chunk.length;
    if (totalSize > maxUncompressedSize) {
      gunzip.destroy();
      fail(label, 'exceeds the uncompressed tar size limit');
    }
    buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
    while (true) {
      if (current) {
        if (buffer.length === 0) break;
        const take = Math.min(buffer.length, current.remaining);
        const dataTake = Math.min(take, current.dataRemaining);
        if (current.chunks && dataTake > 0) current.chunks.push(buffer.subarray(0, dataTake));
        current.dataRemaining -= dataTake;
        current.remaining -= take;
        buffer = buffer.subarray(take);
        if (current.remaining === 0) {
          if (current.chunks) finishMetadata(current);
          current = null;
        }
        continue;
      }
      if (buffer.length < 512) break;
      const headerBytes = buffer.subarray(0, 512);
      buffer = buffer.subarray(512);
      if (headerBytes.every((byte) => byte === 0)) {
        zeroBlocks += 1;
        if (zeroBlocks >= 2) ended = true;
        continue;
      }
      if (ended) fail(label, 'contains nonzero data after the tar end marker');
      zeroBlocks = 0;
      const header = parseTarHeader(headerBytes, label);
      if (['x', 'g', 'L', 'K'].includes(header.typeFlag)) {
        if (header.size > TAR_MAX_METADATA_SIZE) fail(label, 'contains oversized tar metadata');
        current = {
          kind: header.typeFlag, dataSize: header.size, dataRemaining: header.size,
          remaining: Math.ceil(header.size / 512) * 512, chunks: []
        };
      } else {
        const attributes = { ...globalPax, ...(pendingPax ?? {}) };
        const parsed = tarRecord(header, attributes, pendingLongPath, pendingLongLink, label);
        records.push(parsed.record);
        if (records.length > MAX_ARCHIVE_ENTRIES) fail(label, 'contains too many tar entries');
        pendingPax = null;
        pendingLongPath = null;
        pendingLongLink = null;
        current = {
          dataSize: parsed.size, dataRemaining: parsed.size,
          remaining: Math.ceil(parsed.size / 512) * 512, chunks: null
        };
      }
      if (current.remaining === 0) {
        if (current.chunks) finishMetadata(current);
        current = null;
      }
    }
  }
  if (current || buffer.length !== 0 || !ended || pendingPax || pendingLongPath || pendingLongLink) {
    fail(label, 'is truncated or has dangling tar metadata');
  }
  return records;
}

export async function validateTarGzArchive(archivePath, expectedRoot, label = 'tar.gz archive', options = {}) {
  await requireRegularArchive(archivePath, label);
  const maxUncompressedSize = options.maxUncompressedSize ?? TAR_MAX_UNCOMPRESSED_SIZE;
  if (!Number.isSafeInteger(maxUncompressedSize) || maxUncompressedSize <= 0) {
    throw new TypeError('maxUncompressedSize must be a positive safe integer');
  }
  const records = await parseTarGz(archivePath, label, maxUncompressedSize);
  return validateArchiveEntries(records, expectedRoot, label, options);
}
