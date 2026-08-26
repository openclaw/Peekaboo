#!/usr/bin/env node

import { isUtf8 } from 'node:buffer';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { inflateSync } from 'node:zlib';
import {
  aggregateSHA256,
  exactKeys,
  parseOptions,
  readStableFile,
  readStableJSON,
  requireCondition,
  sameJSON,
  sha256,
  writePrivateExclusive,
} from './lib.mjs';

const ARTIFACTS = ['openclaw_app', 'peekaboo_app', 'peekaboo_cli'];
const HOST_ROLES = ['local', 'studio'];
const HOST_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const SCRIPT_EXTENSIONS = new Set([
  '.applescript', '.bash', '.cjs', '.command', '.js', '.jxa', '.mjs', '.osa', '.pl', '.py',
  '.rb', '.scpt', '.scptd', '.sh', '.swift', '.zsh',
]);
const MACH_O_MAGICS = new Map([
  ['feedface', { bits: 32, endian: 'be', kind: 'thin' }],
  ['cefaedfe', { bits: 32, endian: 'le', kind: 'thin' }],
  ['feedfacf', { bits: 64, endian: 'be', kind: 'thin' }],
  ['cffaedfe', { bits: 64, endian: 'le', kind: 'thin' }],
  ['cafebabe', { bits: 32, endian: 'be', kind: 'fat' }],
  ['bebafeca', { bits: 32, endian: 'le', kind: 'fat' }],
  ['cafebabf', { bits: 64, endian: 'be', kind: 'fat' }],
  ['bfbafeca', { bits: 64, endian: 'le', kind: 'fat' }],
]);
const TEXT_FORBIDDEN_MARKERS = [
  ['apple-script', /(^|[^a-z0-9])(osascript|osascriptd|applescript|nsapplescript|jxa|osaexecute|javascript for automation)([^a-z0-9]|$)/],
  ['cua-driver', /(^|[^a-z0-9])cua-driver([^a-z0-9]|$)/],
  ['virtualization', /(^|[^a-z0-9])(lume|parallels|vmware|virtualbox|virtualization|utm|tart|vfkit|qemu)([^a-z0-9]|$)/],
  ['remote-desktop', /(^|[^a-z0-9])(vnc|screen sharing|screensharing|remote desktop|remotedesktop)([^a-z0-9]|$)/],
];
const STRUCTURAL_NAME_MARKER = /(^|[\/._ -])(cua-driver|osascript|applescript|jxa|lume|parallels|prl_|vmware|virtualbox|virtualization|utm|tart|vfkit|qemu|vnc|screen sharing|screensharing|remote desktop|remotedesktop|jump desktop)([\/._ -]|$)/i;
const APPLE_EVENT_IMPORT = /^_?(?:AE(?:[A-Z][a-z]{2}[A-Za-z0-9_]*|(?:Is|Do)[A-Z][A-Za-z0-9_]*)|OSA[A-Z][a-z][A-Za-z0-9_]*|OBJC_(?:CLASS|METACLASS)_\$_NS(?:AppleScript|AppleEventDescriptor|AppleEventManager|UserAppleScriptTask))$/;
const APPLE_EVENT_CLASS_STRING = /^_?OBJC_(?:CLASS|METACLASS)_\$_NS(?:AppleScript|AppleEventDescriptor|AppleEventManager|UserAppleScriptTask)$/;
const OSAKIT_CLASS_SYMBOL = /^_?OBJC_(?:CLASS|METACLASS)_\$_OSA(?:Language(?:Instance)?|Script(?:Controller|View)?)$/;
const SCRIPTING_BRIDGE_IMPORT = /^_?OBJC_(?:CLASS|METACLASS)_\$_SB(?:Application|ElementArray|Object)$/;
const SCRIPTING_BRIDGE_CLASS_STRING = /^(?:SBApplication|SBElementArray|SBObject)$/;
const VIRTUALIZATION_IMPORT = /^_?(?:VZ[A-Z][A-Za-z0-9_]*|OBJC_(?:CLASS|METACLASS)_\$_VZ[A-Za-z0-9_]+)$/;
const VIRTUALIZATION_CLASS_STRING = /^(?:_?OBJC_(?:CLASS|METACLASS)_\$_VZ[A-Za-z0-9_]+|VZ(?=[A-Z][A-Za-z0-9_]*[a-z])[A-Z][A-Za-z0-9_]*)$/;
const APPLE_FRAMEWORK_PATH = /(?:^|\/)(?:OSAKit|ScriptingBridge)\.framework(?:\/|$)/i;
const VIRTUALIZATION_FRAMEWORK_PATH = /(?:^|\/)(?:Virtualization|Hypervisor)\.framework(?:\/|$)/i;
const APPLE_EVENT_STRING = /^(?:NSAppleScript|NSAppleEventDescriptor|NSAppleEventManager|NSUserAppleScriptTask|OSAKit\.framework|OSAScript|kOSAComponentType|\/usr\/bin\/osascript)$/;
const APPLE_EVENT_DYNAMIC_STRING = /^_?(?:AE(?:[A-Z][a-z]{2}[A-Za-z0-9_]*|(?:Is|Do)[A-Z][A-Za-z0-9_]*)|OSA[A-Z][a-z][A-Za-z0-9_]*)$/;
const APPLE_EVENT_COMPILER_METADATA = /^(?:AESgtGG|AESgtGGGSgtGG)$/;
const LOAD_COMMAND_DYLIBS = new Set([0x0c, 0x0d, 0x18, 0x1f, 0x20, 0x23]);
const MACH_O_CPU_TYPES = new Set([0x00000007, 0x01000007, 0x0000000c, 0x0100000c]);
const CODE_DIRECTORY_MAGIC = 0xfade0c02;

function isAppleScriptImport(value) {
  return APPLE_EVENT_IMPORT.test(value)
    || OSAKIT_CLASS_SYMBOL.test(value)
    || SCRIPTING_BRIDGE_IMPORT.test(value);
}

function isAppleScriptPolicyString(value) {
  return APPLE_EVENT_STRING.test(value)
    || APPLE_EVENT_CLASS_STRING.test(value)
    || OSAKIT_CLASS_SYMBOL.test(value)
    || SCRIPTING_BRIDGE_IMPORT.test(value)
    || SCRIPTING_BRIDGE_CLASS_STRING.test(value)
    || APPLE_FRAMEWORK_PATH.test(value)
    || (!APPLE_EVENT_COMPILER_METADATA.test(value) && APPLE_EVENT_DYNAMIC_STRING.test(value));
}

function isVirtualizationPolicyString(value) {
  return VIRTUALIZATION_CLASS_STRING.test(value) || VIRTUALIZATION_FRAMEWORK_PATH.test(value);
}

function structuralFamily(value) {
  if (/(^|\/)[^/]+\.(?:applescript|jxa|osa|scpt|scptd)(\/|$)/i.test(value)) {
    return 'apple-script';
  }
  if (/(^|[\/._ -])(?:osascriptd)([\/._ -]|$)/i.test(value)) return 'apple-script';
  if (/(^|[\/._ -])(?:cua-driver|cuadriver|trycua)([\/._ -]|$)/i.test(value)) {
    return 'cua-driver';
  }
  if (/(^|[\/._ -])(?:prl_[a-z0-9_-]*|vmware-vmx|virtualboxvm)([\/._ -]|$)/i.test(value)) {
    return 'virtualization';
  }
  if (/(^|[\/._ -])(?:ardagent|rdc|remotedesktopagent|screensharingd|vncserver|vncviewer)([\/._ -]|$)/i.test(value)) {
    return 'remote-desktop';
  }
  const match = value.match(STRUCTURAL_NAME_MARKER);
  if (!match) return null;
  const marker = match[2].toLowerCase();
  if (marker === 'cua-driver') return 'cua-driver';
  if (['osascript', 'applescript', 'jxa'].includes(marker)) return 'apple-script';
  if (['vnc', 'screen sharing', 'screensharing', 'remote desktop', 'remotedesktop', 'jump desktop'].includes(marker)) {
    return 'remote-desktop';
  }
  return 'virtualization';
}

function unsignedInteger(bytes, offset, size, endian) {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset + size > bytes.length) return null;
  if (size === 4) return endian === 'le' ? bytes.readUInt32LE(offset) : bytes.readUInt32BE(offset);
  const value = endian === 'le' ? bytes.readBigUInt64LE(offset) : bytes.readBigUInt64BE(offset);
  return value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : null;
}

function cString(bytes, offset, limit) {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset >= limit || limit > bytes.length) return null;
  let end = offset;
  while (end < limit && bytes[end] !== 0) end += 1;
  if (end === offset || end >= limit) return null;
  const value = bytes.subarray(offset, end);
  return value.every((byte) => byte >= 0x20 && byte <= 0x7e) ? value.toString('ascii') : null;
}

function policyStrings(bytes, excludedRanges = [], ignoredStringRanges = []) {
  const exclusions = excludedRanges
    .filter(({ start, end }) => Number.isSafeInteger(start) && Number.isSafeInteger(end)
      && start >= 0 && end > start && end <= bytes.length)
    .sort((left, right) => left.start - right.start);
  const ignoredStrings = new Set(ignoredStringRanges
    .filter(({ start, end }) => Number.isSafeInteger(start) && Number.isSafeInteger(end)
      && start >= 0 && end > start && end <= bytes.length)
    .map(({ start, end }) => `${start}:${end}`));
  const values = [];
  let start = null;
  let exclusionIndex = 0;
  for (let index = 0; index <= bytes.length; index += 1) {
    while (exclusionIndex < exclusions.length && index >= exclusions[exclusionIndex].end) {
      exclusionIndex += 1;
    }
    const exclusion = exclusions[exclusionIndex];
    const excluded = index < bytes.length && exclusion
      && index >= exclusion.start && index < exclusion.end;
    const printable = index < bytes.length && !excluded
      && bytes[index] >= 0x20 && bytes[index] <= 0x7e;
    if (printable && start === null) start = index;
    if (!printable && start !== null) {
      if (index - start >= 4 && !ignoredStrings.has(`${start}:${index}`)) {
        const value = bytes.subarray(start, index).toString('ascii');
        if (isAppleScriptPolicyString(value) || isVirtualizationPolicyString(value)) {
          values.push(value);
        }
      }
      start = null;
    }
  }
  return values;
}

function codeDirectoryIdentifiers(bytes, offset, size) {
  const identifiers = [];
  const parseCodeDirectory = (start, maximum) => {
    if (start < offset || start + 24 > maximum || maximum > offset + size) return false;
    const magic = bytes.readUInt32BE(start);
    if (magic !== CODE_DIRECTORY_MAGIC) return false;
    const length = bytes.readUInt32BE(start + 4);
    const identifierOffset = bytes.readUInt32BE(start + 20);
    if (length < 24 || start + length > maximum || identifierOffset >= length) return false;
    const identifier = cString(bytes, start + identifierOffset, start + length);
    if (!identifier) return false;
    identifiers.push(identifier);
    return true;
  };
  if (offset < 0 || size < 8 || offset + size > bytes.length) return null;
  const magic = bytes.readUInt32BE(offset);
  if (magic === CODE_DIRECTORY_MAGIC) {
    const length = bytes.readUInt32BE(offset + 4);
    return length <= size && parseCodeDirectory(offset, offset + length)
      ? { identifiers, validatedSize: length }
      : null;
  }
  if (magic !== 0xfade0cc0 || size < 12) return null;
  const length = bytes.readUInt32BE(offset + 4);
  const count = bytes.readUInt32BE(offset + 8);
  if (length < 12 || length > size || count === 0 || count > 1024 || 12 + count * 8 > length) {
    return null;
  }
  for (let index = 0; index < count; index += 1) {
    const blobOffset = bytes.readUInt32BE(offset + 12 + index * 8 + 4);
    if (blobOffset < 12 + count * 8 || blobOffset + 8 > length) return null;
    const blobMagic = bytes.readUInt32BE(offset + blobOffset);
    if (blobMagic === CODE_DIRECTORY_MAGIC
      && !parseCodeDirectory(offset + blobOffset, offset + length)) return null;
  }
  return identifiers.length > 0 ? { identifiers, validatedSize: length } : null;
}

function symbolNameDecoder(bytes, offset, size) {
  if (size === 0 || offset < 0 || offset + size > bytes.length) return null;
  const cache = new Map();
  let remainingBytes = size * 4;
  return (nameOffset) => {
    if (!Number.isSafeInteger(nameOffset) || nameOffset < 0 || nameOffset >= size) {
      return { ok: false, value: null };
    }
    if (cache.has(nameOffset)) return cache.get(nameOffset);
    let cursor = nameOffset;
    while (cursor < size && bytes[offset + cursor] !== 0) {
      remainingBytes -= 1;
      if (remainingBytes < 0) return { ok: false, value: null };
      const byte = bytes[offset + cursor];
      if (byte < 0x20 || byte > 0x7e) return { ok: false, value: null };
      cursor += 1;
    }
    if (cursor >= size || cursor === nameOffset) return { ok: false, value: null };
    const result = {
      ok: true,
      value: bytes.subarray(offset + nameOffset, offset + cursor).toString('ascii'),
    };
    cache.set(nameOffset, result);
    return result;
  };
}

function chainedFixupPolicyImports(bytes, offset, size, endian) {
  if (offset < 0 || size < 28 || offset + size > bytes.length) return null;
  const read32 = (relativeOffset) => unsignedInteger(bytes, offset + relativeOffset, 4, endian);
  const version = read32(0);
  const startsOffset = read32(4);
  const importsOffset = read32(8);
  const symbolsOffset = read32(12);
  const importsCount = read32(16);
  const importsFormat = read32(20);
  const symbolsFormat = read32(24);
  if (version !== 0 || startsOffset === null || startsOffset < 28 || startsOffset >= size
    || importsOffset === null || importsOffset < 28 || importsOffset >= size
    || symbolsOffset === null || symbolsOffset < 28 || symbolsOffset >= size
    || importsCount === null || importsCount > 2_000_000
    || ![1, 2, 3].includes(importsFormat) || ![0, 1].includes(symbolsFormat)) return null;
  const entrySize = importsFormat === 1 ? 4 : importsFormat === 2 ? 8 : 16;
  const importsEnd = importsOffset + importsCount * entrySize;
  if (!Number.isSafeInteger(importsEnd) || importsEnd > symbolsOffset) return null;

  let symbolBytes;
  try {
    const encodedSymbols = bytes.subarray(offset + symbolsOffset, offset + size);
    symbolBytes = symbolsFormat === 0
      ? encodedSymbols
      : inflateSync(encodedSymbols, { maxOutputLength: 64 * 1024 * 1024 });
  } catch {
    return null;
  }
  if (importsCount > 0 && symbolBytes.length === 0) return null;
  const decodeSymbolName = importsCount > 0
    ? symbolNameDecoder(symbolBytes, 0, symbolBytes.length)
    : null;
  if (importsCount > 0 && !decodeSymbolName) return null;

  const imports = [];
  for (let index = 0; index < importsCount; index += 1) {
    const entryOffset = offset + importsOffset + index * entrySize;
    let nameOffset;
    if (importsFormat === 3) {
      const value = endian === 'le'
        ? bytes.readBigUInt64LE(entryOffset)
        : bytes.readBigUInt64BE(entryOffset);
      if (((value >> 17n) & 0x7fffn) !== 0n) return null;
      const rawNameOffset = value >> 32n;
      if (rawNameOffset > BigInt(Number.MAX_SAFE_INTEGER)) return null;
      nameOffset = Number(rawNameOffset);
    } else {
      const value = unsignedInteger(bytes, entryOffset, 4, endian);
      if (value === null) return null;
      nameOffset = value >>> 9;
    }
    const decoded = decodeSymbolName(nameOffset);
    if (!decoded.ok || !decoded.value) return null;
    const name = decoded.value;
    if (isAppleScriptImport(name) || VIRTUALIZATION_IMPORT.test(name)) imports.push(name);
  }
  return imports;
}

function thinMachOSlice(bytes, offset, size) {
  if (offset < 0 || size < 28 || offset + size > bytes.length) return null;
  const magic = bytes.subarray(offset, offset + 4).toString('hex');
  const format = MACH_O_MAGICS.get(magic);
  if (!format || format.kind !== 'thin') return null;
  const headerSize = format.bits === 64 ? 32 : 28;
  const cpuType = unsignedInteger(bytes, offset + 4, 4, format.endian);
  const cpuSubtype = unsignedInteger(bytes, offset + 8, 4, format.endian);
  const fileType = unsignedInteger(bytes, offset + 12, 4, format.endian);
  const commandCount = unsignedInteger(bytes, offset + 16, 4, format.endian);
  const commandBytes = unsignedInteger(bytes, offset + 20, 4, format.endian);
  if (cpuType === null || cpuSubtype === null || fileType === null
    || !MACH_O_CPU_TYPES.has(cpuType) || fileType < 1 || fileType > 12
    || commandCount === null || commandCount === 0 || commandCount > 65_536
    || commandBytes === null || commandBytes < commandCount * 8
    || headerSize + commandBytes > size) return null;
  const loadPaths = [];
  const imports = [];
  const identifiers = [];
  let symbolTable = null;
  let sawChainedFixups = false;
  const policyStringExclusions = [];
  const ignoredPolicyStringRanges = [];
  let sawCodeSignature = false;
  let sawSegment = false;
  let cursor = offset + headerSize;
  const commandLimit = cursor + commandBytes;
  for (let index = 0; index < commandCount; index += 1) {
    if (cursor + 8 > commandLimit) return null;
    const command = unsignedInteger(bytes, cursor, 4, format.endian);
    const commandSize = unsignedInteger(bytes, cursor + 4, 4, format.endian);
    if (command === null || commandSize === null || commandSize < 8
      || commandSize % (format.bits === 64 ? 8 : 4) !== 0
      || cursor + commandSize > commandLimit) return null;
    const baseCommand = command & 0x7fffffff;
    if (baseCommand === 0x01 || baseCommand === 0x19) {
      const is64BitSegment = baseCommand === 0x19;
      const expectedSegmentCommand = format.bits === 64 ? 0x19 : 0x01;
      const minimumSize = is64BitSegment ? 72 : 56;
      const sectionSize = is64BitSegment ? 80 : 68;
      if (baseCommand !== expectedSegmentCommand || commandSize < minimumSize) return null;
      const sectionCount = unsignedInteger(
        bytes,
        cursor + (is64BitSegment ? 64 : 48),
        4,
        format.endian,
      );
      const fileOffset = unsignedInteger(
        bytes,
        cursor + (is64BitSegment ? 40 : 32),
        is64BitSegment ? 8 : 4,
        format.endian,
      );
      const fileSize = unsignedInteger(
        bytes,
        cursor + (is64BitSegment ? 48 : 36),
        is64BitSegment ? 8 : 4,
        format.endian,
      );
      if (sectionCount === null || sectionCount > 4096
        || minimumSize + sectionCount * sectionSize !== commandSize
        || fileOffset === null || fileSize === null || fileOffset + fileSize > size) return null;
      sawSegment = true;
    } else if (LOAD_COMMAND_DYLIBS.has(baseCommand)) {
      if (commandSize < 24) return null;
      const nameOffset = unsignedInteger(bytes, cursor + 8, 4, format.endian);
      if (nameOffset === null || nameOffset < 24 || nameOffset >= commandSize) return null;
      const name = cString(bytes, cursor + nameOffset, cursor + commandSize);
      if (!name) return null;
      loadPaths.push(name);
    } else if (baseCommand === 0x02) {
      if (commandSize < 24 || symbolTable !== null) return null;
      symbolTable = {
        symbolOffset: unsignedInteger(bytes, cursor + 8, 4, format.endian),
        symbolCount: unsignedInteger(bytes, cursor + 12, 4, format.endian),
        stringOffset: unsignedInteger(bytes, cursor + 16, 4, format.endian),
        stringSize: unsignedInteger(bytes, cursor + 20, 4, format.endian),
      };
    } else if (baseCommand === 0x1d) {
      if (commandSize < 16 || sawCodeSignature) return null;
      sawCodeSignature = true;
      const signatureOffset = unsignedInteger(bytes, cursor + 8, 4, format.endian);
      const signatureSize = unsignedInteger(bytes, cursor + 12, 4, format.endian);
      if (signatureOffset === null || signatureSize === null || signatureSize === 0
        || signatureOffset + signatureSize > size) return null;
      const codeSignature = codeDirectoryIdentifiers(
        bytes,
        offset + signatureOffset,
        signatureSize,
      );
      if (!codeSignature) return null;
      policyStringExclusions.push({
        start: signatureOffset,
        end: signatureOffset + codeSignature.validatedSize,
      });
      identifiers.push(...codeSignature.identifiers);
    } else if (baseCommand === 0x34) {
      if (commandSize < 16 || sawChainedFixups) return null;
      sawChainedFixups = true;
      const fixupsOffset = unsignedInteger(bytes, cursor + 8, 4, format.endian);
      const fixupsSize = unsignedInteger(bytes, cursor + 12, 4, format.endian);
      if (fixupsOffset === null || fixupsSize === null || fixupsSize === 0
        || fixupsOffset + fixupsSize > size) return null;
      const chainedImports = chainedFixupPolicyImports(
        bytes,
        offset + fixupsOffset,
        fixupsSize,
        format.endian,
      );
      if (!chainedImports) return null;
      imports.push(...chainedImports);
    }
    cursor += commandSize;
  }
  if (cursor !== commandLimit || !sawSegment || !symbolTable) return null;
  const { symbolOffset, symbolCount, stringOffset, stringSize } = symbolTable;
  const symbolSize = format.bits === 64 ? 16 : 12;
  if ([symbolOffset, symbolCount, stringOffset, stringSize].some((value) => value === null)
    || symbolCount > 2_000_000
    || symbolOffset + symbolCount * symbolSize > size
    || stringOffset + stringSize > size) return null;
  const decodeSymbolName = symbolNameDecoder(bytes, offset + stringOffset, stringSize);
  if (!decodeSymbolName) return null;
  for (let index = 0; index < symbolCount; index += 1) {
    const entryOffset = offset + symbolOffset + index * symbolSize;
    const nameOffset = unsignedInteger(bytes, entryOffset, 4, format.endian);
    const type = bytes[entryOffset + 4];
    const symbolType = type & 0x0e;
    const isImportedExternal = (type & 0xe0) === 0 && (type & 0x01) === 1
      && (symbolType === 0 || symbolType === 0x0c);
    if (nameOffset === null || nameOffset >= stringSize) {
      if (isImportedExternal) return null;
      continue;
    }
    if (nameOffset === 0 && !isImportedExternal) continue;
    const decoded = decodeSymbolName(nameOffset);
    if (!decoded.ok || !decoded.value) {
      if (isImportedExternal) return null;
      continue;
    }
    const name = decoded.value;
    if (!isImportedExternal) {
      ignoredPolicyStringRanges.push({
        start: stringOffset + nameOffset,
        end: stringOffset + nameOffset + name.length,
      });
      continue;
    }
    if (name && (isAppleScriptImport(name) || VIRTUALIZATION_IMPORT.test(name))) {
      imports.push(name);
    }
  }
  return {
    cpuSubtype,
    cpuType,
    identifiers,
    imports,
    loadPaths,
    strings: policyStrings(
      bytes.subarray(offset, offset + size),
      policyStringExclusions,
      ignoredPolicyStringRanges,
    ),
  };
}

function machOEvidence(bytes) {
  if (bytes.length < 4) return null;
  const magic = bytes.subarray(0, 4).toString('hex');
  const format = MACH_O_MAGICS.get(magic);
  if (!format) return null;
  if (format.kind === 'thin') return thinMachOSlice(bytes, 0, bytes.length);
  if (bytes.length < 8) return null;
  const count = unsignedInteger(bytes, 4, 4, format.endian);
  const entrySize = format.bits === 64 ? 32 : 20;
  if (count === null || count === 0 || count > 128 || 8 + count * entrySize > bytes.length) return null;
  const tableEnd = 8 + count * entrySize;
  const records = [];
  const architectures = new Set();
  for (let index = 0; index < count; index += 1) {
    const entry = 8 + index * entrySize;
    const cpuType = unsignedInteger(bytes, entry, 4, format.endian);
    const cpuSubtype = unsignedInteger(bytes, entry + 4, 4, format.endian);
    const offset = unsignedInteger(bytes, entry + 8, format.bits === 64 ? 8 : 4, format.endian);
    const size = unsignedInteger(bytes, entry + (format.bits === 64 ? 16 : 12),
      format.bits === 64 ? 8 : 4, format.endian);
    const alignment = unsignedInteger(bytes, entry + (format.bits === 64 ? 24 : 16), 4, format.endian);
    const reserved = format.bits === 64
      ? unsignedInteger(bytes, entry + 28, 4, format.endian)
      : 0;
    if (cpuType === null || cpuSubtype === null || !MACH_O_CPU_TYPES.has(cpuType)
      || offset === null || size === null || size === 0 || offset < tableEnd
      || offset + size > bytes.length || alignment === null || alignment > 31
      || offset % (2 ** alignment) !== 0 || reserved !== 0) return null;
    const architecture = `${cpuType}:${cpuSubtype}`;
    if (architectures.has(architecture)) return null;
    architectures.add(architecture);
    records.push({ cpuSubtype, cpuType, offset, size });
  }
  const ordered = [...records].sort((left, right) => left.offset - right.offset);
  for (let index = 1; index < ordered.length; index += 1) {
    if (ordered[index - 1].offset + ordered[index - 1].size > ordered[index].offset) return null;
  }
  const evidence = { identifiers: [], imports: [], loadPaths: [], strings: [] };
  for (const record of records) {
    const slice = thinMachOSlice(bytes, record.offset, record.size);
    if (!slice || slice.cpuType !== record.cpuType || slice.cpuSubtype !== record.cpuSubtype) return null;
    for (const key of ['identifiers', 'imports', 'loadPaths', 'strings']) {
      for (const value of slice[key]) evidence[key].push(value);
    }
  }
  return evidence;
}

export function policyFindingsForFile(relativePath, mode, bytes) {
  const kind = classifyPolicyFile(relativePath, mode, bytes);
  if (kind === 'data') return [];
  const families = new Set();
  const pathFamily = structuralFamily(relativePath);
  if (pathFamily) families.add(pathFamily);
  if (kind === 'script') {
    const searchable = bytes.toString('utf8').toLowerCase();
    for (const [family, expression] of TEXT_FORBIDDEN_MARKERS) {
      if (expression.test(searchable)) families.add(family);
    }
  } else {
    const evidence = machOEvidence(bytes);
    if (!evidence) {
      families.add('uninspectable-native-executable');
    } else {
      for (const identifier of evidence.identifiers) {
        const family = structuralFamily(identifier);
        if (family) families.add(family);
      }
      for (const loadPath of evidence.loadPaths) {
        const family = structuralFamily(loadPath);
        if (family) families.add(family);
        if (APPLE_FRAMEWORK_PATH.test(loadPath)) {
          families.add('apple-script');
        }
        if (VIRTUALIZATION_FRAMEWORK_PATH.test(loadPath)) {
          families.add('virtualization');
        }
      }
      if (evidence.imports.some((value) => isAppleScriptImport(value))) {
        families.add('apple-script');
      }
      if (evidence.imports.some((value) => VIRTUALIZATION_IMPORT.test(value))) {
        families.add('virtualization');
      }
      if (evidence.strings.some((value) => isAppleScriptPolicyString(value))) {
        families.add('apple-script');
      }
      if (evidence.strings.some((value) => isVirtualizationPolicyString(value))) {
        families.add('virtualization');
      }
    }
  }
  return [...families].sort().map((family) => ({ family }));
}

function safeRelativePath(value, label) {
  requireCondition(typeof value === 'string' && value.length > 0 && !path.isAbsolute(value)
    && !value.includes('\0') && !value.includes('\n')
    && !value.split('/').some((component) => component === '' || component === '.' || component === '..'),
  `${label} is not one safe relative path`);
  return value;
}

function inventory(filePath) {
  const retained = readStableJSON(filePath, 'policy scanner installed inventory', {
    maximumBytes: 256 * 1024 * 1024,
  });
  const value = retained.value;
  exactKeys(value, [
    'version', 'role', 'host_uuid', 'hostname', 'deployment_envelope_sha256',
    'peekaboo_source_commit', 'openclaw_source_commit', 'qualification_tools_aggregate_sha256',
    'elevation_receipt_sha256', 'captured_at_milliseconds', 'entries', 'aggregate_sha256',
  ], 'policy scanner installed inventory');
  requireCondition(value.version === 1 && HOST_ROLES.includes(value.role)
    && HOST_UUID.test(value.host_uuid) && HEX64.test(value.deployment_envelope_sha256)
    && HEX40.test(value.peekaboo_source_commit) && HEX40.test(value.openclaw_source_commit)
    && HEX64.test(value.qualification_tools_aggregate_sha256)
    && HEX64.test(value.elevation_receipt_sha256)
    && Number.isSafeInteger(value.captured_at_milliseconds)
    && value.captured_at_milliseconds > 0 && Array.isArray(value.entries)
    && value.entries.length > 0,
  'policy scanner installed inventory is malformed');
  const entries = value.entries.map((entry, index) => {
    const common = ['artifact', 'relative_path', 'type', 'mode'];
    const specific = entry?.type === 'file' ? ['size', 'sha256']
      : entry?.type === 'symlink' ? ['target'] : [];
    exactKeys(entry, [...common, ...specific], `policy scanner inventory entry ${index}`);
    requireCondition(ARTIFACTS.includes(entry.artifact)
      && Number.isSafeInteger(entry.mode) && entry.mode >= 0 && entry.mode <= 0o7777,
    `policy scanner inventory entry ${index} is malformed`);
    safeRelativePath(entry.relative_path, `policy scanner inventory entry ${index}`);
    if (entry.type === 'file') {
      requireCondition(Number.isSafeInteger(entry.size) && entry.size >= 0
        && HEX64.test(entry.sha256), `policy scanner inventory entry ${index} file is malformed`);
    } else {
      requireCondition(entry.type === 'symlink' && typeof entry.target === 'string'
        && entry.target.length > 0 && !/[\0\n]/.test(entry.target),
      `policy scanner inventory entry ${index} symlink is malformed`);
    }
    return entry;
  });
  const keys = entries.map((entry) => `${entry.artifact}\0${entry.relative_path}`);
  requireCondition(new Set(keys).size === keys.length
    && keys.every((key, index) => index === 0 || keys[index - 1] < key)
    && ARTIFACTS.every((artifact) => entries.some((entry) => entry.artifact === artifact)),
  'policy scanner installed inventory is not canonical and complete');
  const projection = {
    deployment_envelope_sha256: value.deployment_envelope_sha256,
    peekaboo_source_commit: value.peekaboo_source_commit,
    openclaw_source_commit: value.openclaw_source_commit,
    qualification_tools_aggregate_sha256: value.qualification_tools_aggregate_sha256,
    entries,
  };
  requireCondition(value.aggregate_sha256 === aggregateSHA256('installed-inventory', projection),
    'policy scanner installed inventory aggregate is invalid');
  return { retained, value, entries };
}

function artifactRoots(value) {
  exactKeys(value, ARTIFACTS, 'policy scanner artifact roots');
  return Object.fromEntries(ARTIFACTS.map((artifact) => {
    const root = value[artifact];
    requireCondition(typeof root === 'string' && path.isAbsolute(root)
      && fs.realpathSync(root) === root, `policy scanner ${artifact} root is not canonical`);
    const info = fs.lstatSync(root, { bigint: true });
    requireCondition(info.isDirectory() && !info.isSymbolicLink(),
      `policy scanner ${artifact} root is not one real directory`);
    return [artifact, root];
  }));
}

export function classifyPolicyFile(relativePath, mode, bytes) {
  const magic = bytes.length >= 4 ? bytes.subarray(0, 4).toString('hex') : null;
  if (MACH_O_MAGICS.has(magic)) return 'executable';
  if (bytes.subarray(0, 2).equals(Buffer.from('#!'))
    || SCRIPT_EXTENSIONS.has(path.extname(relativePath).toLowerCase())) return 'script';
  if ((mode & 0o111) !== 0) {
    const text = isUtf8(bytes) && bytes.every((byte) => (
      byte === 0x09 || byte === 0x0a || byte === 0x0d || (byte >= 0x20 && byte !== 0x7f)
    ));
    return text ? 'script' : 'executable';
  }
  return 'data';
}

function findingsFor(entry, bytes) {
  return policyFindingsForFile(entry.relative_path, entry.mode, bytes).map(({ family }) => ({
    artifact: entry.artifact,
    relative_path: entry.relative_path,
    family,
  }));
}

function scanInstalledInventory(inventoryPath, rootsValue) {
  const installed = inventory(inventoryPath);
  const roots = artifactRoots(rootsValue);
  const fileCoverage = [];
  const forbiddenFindings = [];
  for (const [index, entry] of installed.entries.entries()) {
    const root = roots[entry.artifact];
    const filePath = path.join(root, entry.relative_path);
    requireCondition(path.relative(root, filePath) === entry.relative_path,
      `policy scanner inventory entry ${index} escapes its artifact root`);
    const info = fs.lstatSync(filePath, { bigint: true });
    const mode = Number(info.mode & 0o7777n);
    requireCondition(mode === entry.mode, `policy scanner inventory entry ${index} mode changed`);
    if (entry.type === 'symlink') {
      requireCondition(info.isSymbolicLink() && fs.readlinkSync(filePath) === entry.target
        && fs.realpathSync(path.dirname(filePath)) === path.dirname(filePath),
        `policy scanner inventory entry ${index} symlink changed`);
      const resolvedTarget = path.resolve(path.dirname(filePath), entry.target);
      const relativeTarget = path.relative(root, resolvedTarget);
      requireCondition(!path.isAbsolute(entry.target)
        && relativeTarget !== '..' && !relativeTarget.startsWith(`..${path.sep}`),
      `policy scanner inventory entry ${index} symlink escapes its artifact root`);
      const families = new Set([
        structuralFamily(entry.relative_path),
        structuralFamily(entry.target),
        structuralFamily(relativeTarget),
      ].filter(Boolean));
      forbiddenFindings.push(...[...families].sort().map((family) => ({
        artifact: entry.artifact,
        relative_path: entry.relative_path,
        family,
      })));
      continue;
    }
    requireCondition(info.isFile() && !info.isSymbolicLink() && info.nlink === 1n
      && fs.realpathSync(filePath) === filePath,
      `policy scanner inventory entry ${index} is not one regular file`);
    const retained = readStableFile(filePath, `policy scanner inventory entry ${index}`, {
      privateFile: false,
      maximumBytes: 512 * 1024 * 1024,
    });
    requireCondition(retained.bytes.length === entry.size && retained.sha256 === entry.sha256,
      `policy scanner inventory entry ${index} bytes changed`);
    const kind = classifyPolicyFile(entry.relative_path, entry.mode, retained.bytes);
    fileCoverage.push({
      artifact: entry.artifact,
      relative_path: entry.relative_path,
      sha256: retained.sha256,
      classification: kind,
    });
    forbiddenFindings.push(...findingsFor(entry, retained.bytes));
  }
  const scannerPath = fs.realpathSync(fileURLToPath(import.meta.url));
  const scanner = readStableFile(scannerPath, 'executable policy scanner source', {
    privateFile: false,
  });
  const coverage = {
    scanner_sha256: scanner.sha256,
    installed_inventory_sha256: installed.retained.sha256,
    installed_inventory_aggregate_sha256: installed.value.aggregate_sha256,
    artifact_roots: roots,
    scanned_roots: ARTIFACTS,
    covered_entries: installed.entries,
    file_coverage: fileCoverage,
  };
  return {
    version: 2,
    role: installed.value.role,
    host_uuid: installed.value.host_uuid,
    deployment_envelope_sha256: installed.value.deployment_envelope_sha256,
    scanner_path: scannerPath,
    scanner_sha256: scanner.sha256,
    complete: true,
    installed_inventory_path: installed.retained.path,
    installed_inventory_sha256: installed.retained.sha256,
    installed_inventory_aggregate_sha256: installed.value.aggregate_sha256,
    artifact_roots: roots,
    scanned_roots: ARTIFACTS,
    covered_entries: installed.entries,
    file_coverage: fileCoverage,
    coverage_aggregate_sha256: aggregateSHA256('executable-policy-coverage', coverage),
    scanned_executable_count: fileCoverage.filter((entry) => entry.classification === 'executable').length,
    scanned_script_count: fileCoverage.filter((entry) => entry.classification === 'script').length,
    forbidden_findings: forbiddenFindings,
  };
}

export function generatePolicyReport(specPath, outputPath) {
  const spec = readStableJSON(specPath, 'policy scanner spec').value;
  exactKeys(spec, ['version', 'installed_inventory', 'artifact_roots'], 'policy scanner spec');
  requireCondition(spec.version === 1 && typeof spec.installed_inventory === 'string',
    'policy scanner spec is malformed');
  const report = scanInstalledInventory(spec.installed_inventory, spec.artifact_roots);
  requireCondition(report.forbidden_findings.length === 0,
    'policy scanner found forbidden executable or script policy evidence');
  const written = writePrivateExclusive(outputPath, report);
  return { report, sha256: written.sha256 };
}

export function verifyPolicyReport(inventoryPath, reportPath) {
  const retained = readStableJSON(reportPath, 'executable policy report');
  const report = retained.value;
  requireCondition(report && typeof report === 'object' && !Array.isArray(report)
    && report.installed_inventory_path === inventoryPath,
  'executable policy report names another installed inventory');
  const expected = scanInstalledInventory(inventoryPath, report.artifact_roots);
  requireCondition(expected.forbidden_findings.length === 0,
    'executable policy scan has forbidden findings');
  requireCondition(sameJSON(report, expected),
    'executable policy report differs from a fresh source-owned scan');
  return {
    version: 1,
    valid: true,
    report_sha256: retained.sha256,
    coverage_aggregate_sha256: expected.coverage_aggregate_sha256,
  };
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const [action, ...argv] = process.argv.slice(2);
    if (action === 'generate') {
      const options = parseOptions(argv, ['spec', 'output']);
      const result = generatePolicyReport(options.spec, options.output);
      process.stdout.write(`${JSON.stringify({ output: options.output, sha256: result.sha256 })}\n`);
    } else if (action === 'verify') {
      const options = parseOptions(argv, ['inventory', 'report']);
      process.stdout.write(`${JSON.stringify(verifyPolicyReport(options.inventory, options.report))}\n`);
    } else {
      throw new Error('usage: executable-policy-scanner.mjs generate|verify ...');
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
