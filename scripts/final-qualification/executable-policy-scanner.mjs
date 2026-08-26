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
const APPLE_EVENT_STRING = /^(?:NSAppleScript|NSAppleEventDescriptor|NSAppleEventManager|NSUserAppleScriptTask|OSAKit\.framework|OSAScript|kOSAComponentType)$/;
const OSASCRIPT_EXECUTABLE_STRING = /^(?:\/usr\/bin\/)?osascript(?:$|[ \t].*)$/i;
const APPLE_SCRIPT_COMPONENT_STRING = /^\/System\/Library\/Components\/AppleScript\.component(?:$|\/Contents\/MacOS\/AppleScript(?:$|[ \t].*))$/i;
const APPLE_EVENT_DYNAMIC_STRING = /^_?(?:AE(?:[A-Z][a-z]{2}[A-Za-z0-9_]*|(?:Is|Do)[A-Z][A-Za-z0-9_]*)|OSA[A-Z][a-z][A-Za-z0-9_]*)$/;
const APPLE_EVENT_COMPILER_METADATA = /^(?:AESgtGG|AESgtGGGSgtGG)$/;
const LOAD_COMMAND_DYLIBS = new Set([0x0c, 0x0d, 0x18, 0x1f, 0x20, 0x23]);
const MACH_O_CPU_TYPES = new Set([0x00000007, 0x01000007, 0x0000000c, 0x0100000c]);
const CPU_SUBTYPE_VALUE_MASK = 0x00ffffff;
const CODE_DIRECTORY_MAGIC = 0xfade0c02;
const CODE_DIRECTORY_HASH_SIZES = new Map([[1, 20], [2, 32], [3, 20], [4, 48]]);
const SUPERBLOB_SLOT_MAGICS = new Map([
  [2, 0xfade0c01],
  [5, 0xfade7171],
  [7, 0xfade7172],
  [8, 0xfade8181],
  [9, 0xfade8181],
  [10, 0xfade8181],
  [11, 0xfade8181],
  [0x10000, 0xfade0b01],
]);
// macOS 26's fixup-chains.h defines contiguous DYLD_CHAINED_PTR_* values 1 through 16.
const CHAINED_POINTER_FORMATS = new Set([
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
]);

function isAppleScriptImport(value) {
  return APPLE_EVENT_IMPORT.test(value)
    || OSAKIT_CLASS_SYMBOL.test(value)
    || SCRIPTING_BRIDGE_IMPORT.test(value);
}

function isAppleScriptPolicyString(value) {
  return APPLE_EVENT_STRING.test(value)
    || OSASCRIPT_EXECUTABLE_STRING.test(value)
    || APPLE_SCRIPT_COMPONENT_STRING.test(value)
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
  if (size === 2) return endian === 'le' ? bytes.readUInt16LE(offset) : bytes.readUInt16BE(offset);
  if (size === 4) return endian === 'le' ? bytes.readUInt32LE(offset) : bytes.readUInt32BE(offset);
  if (size !== 8) return null;
  const value = endian === 'le' ? bytes.readBigUInt64LE(offset) : bytes.readBigUInt64BE(offset);
  return value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : null;
}

function unsignedBigInteger(bytes, offset, endian) {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset + 8 > bytes.length) return null;
  return endian === 'le' ? bytes.readBigUInt64LE(offset) : bytes.readBigUInt64BE(offset);
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
    if (start < offset || start + 44 > maximum || maximum > offset + size) return false;
    const magic = bytes.readUInt32BE(start);
    if (magic !== CODE_DIRECTORY_MAGIC) return false;
    const length = bytes.readUInt32BE(start + 4);
    const version = bytes.readUInt32BE(start + 8);
    const headerSize = version >= 0x20600 ? 108
      : version >= 0x20500 ? 96
        : version >= 0x20400 ? 88
          : version >= 0x20300 ? 64
            : version >= 0x20200 ? 52
              : version >= 0x20100 ? 48 : 44;
    if (version < 0x20001 || version > 0x20600 || length < headerSize
      || start + length > maximum) return false;
    const hashOffset = bytes.readUInt32BE(start + 16);
    const identifierOffset = bytes.readUInt32BE(start + 20);
    const specialSlotCount = bytes.readUInt32BE(start + 24);
    const codeSlotCount = bytes.readUInt32BE(start + 28);
    const codeLimit = bytes.readUInt32BE(start + 32);
    const hashSize = bytes[start + 36];
    const hashType = bytes[start + 37];
    const pageSize = bytes[start + 39];
    const spare2 = bytes.readUInt32BE(start + 40);
    const specialHashBytes = specialSlotCount * hashSize;
    const codeHashBytes = codeSlotCount * hashSize;
    const hashStart = hashOffset - specialHashBytes;
    const hashEnd = hashOffset + codeHashBytes;
    const scatterOffset = version >= 0x20100 && start + 48 <= maximum
      ? bytes.readUInt32BE(start + 44)
      : 0;
    const codeLimit64 = version >= 0x20300 && start + 64 <= maximum
      ? Number(bytes.readBigUInt64BE(start + 56))
      : 0;
    // Apple Security CodeDirectory::signingLimit gives any nonzero 64-bit extension precedence.
    const signingLimit = version >= 0x20300 && codeLimit64 > 0 ? codeLimit64 : codeLimit;
    const requiredCodeSlots = pageSize === 0
      ? (signingLimit > 0 ? 1 : 0)
      : (signingLimit > 0 ? Math.ceil(signingLimit / (2 ** pageSize)) : -1);
    let scatterValid = start + length <= maximum && hashStart >= headerSize && hashStart <= length;
    if (scatterOffset !== 0) {
      if (!scatterValid || scatterOffset < headerSize || scatterOffset + 24 > hashStart) {
        scatterValid = false;
      } else {
        let scatterCursor = scatterOffset;
        let pagesConsumed = 0;
        let previousPageEnd = 0;
        let sawSentinel = false;
        while (scatterCursor + 24 <= hashStart) {
          const count = bytes.readUInt32BE(start + scatterCursor);
          if (count === 0) {
            sawSentinel = true;
            break;
          }
          const base = bytes.readUInt32BE(start + scatterCursor + 4);
          const pageEnd = base + count;
          const targetOffset = bytes.readBigUInt64BE(start + scatterCursor + 8);
          const spare = bytes.readBigUInt64BE(start + scatterCursor + 16);
          pagesConsumed += count;
          // CS_Scatter.base is a logical page number; hash slots are the cumulative counts.
          if (!Number.isSafeInteger(pagesConsumed) || pagesConsumed > codeSlotCount
            || !Number.isSafeInteger(pageEnd) || pageEnd > 0xffffffff || base < previousPageEnd
            || targetOffset > BigInt(Number.MAX_SAFE_INTEGER) || spare !== 0n) {
            scatterValid = false;
            break;
          }
          previousPageEnd = pageEnd;
          scatterCursor += 24;
        }
        if (!sawSentinel || pagesConsumed !== codeSlotCount) scatterValid = false;
      }
    }
    const teamOffset = version >= 0x20200 ? bytes.readUInt32BE(start + 48) : 0;
    const teamIdentifier = teamOffset === 0 ? null : cString(bytes, start + teamOffset, start + length);
    const spare3 = version >= 0x20300 ? bytes.readUInt32BE(start + 52) : 0;
    const execSegmentBase = version >= 0x20400 ? bytes.readBigUInt64BE(start + 64) : 0n;
    const execSegmentLimit = version >= 0x20400 ? bytes.readBigUInt64BE(start + 72) : 0n;
    const execSegmentFlags = version >= 0x20400 ? bytes.readBigUInt64BE(start + 80) : 0n;
    const preEncryptOffset = version >= 0x20500 ? bytes.readUInt32BE(start + 92) : 0;
    const preEncryptEnd = preEncryptOffset + codeSlotCount * hashSize;
    const linkageHashType = version >= 0x20600 ? bytes[start + 96] : 0;
    const linkageApplicationType = version >= 0x20600 ? bytes[start + 97] : 0;
    const linkageApplicationSubType = version >= 0x20600 ? bytes.readUInt16BE(start + 98) : 0;
    const linkageOffset = version >= 0x20600 ? bytes.readUInt32BE(start + 100) : 0;
    const linkageSize = version >= 0x20600 ? bytes.readUInt32BE(start + 104) : 0;
    const linkageEnd = linkageOffset + linkageSize;
    const linkageHashSize = CODE_DIRECTORY_HASH_SIZES.get(linkageHashType);
    const linkageApplicationValid = linkageApplicationType === 1
      ? linkageApplicationSubType === 0
      : linkageApplicationType === 2 && [1, 2].includes(linkageApplicationSubType);
    const execSegmentEnd = execSegmentBase + execSegmentLimit;
    // Security CodeDirectory::checkIntegrity applies this slot-count rule after scatter validation too.
    if (version < 0x20001 || version > 0x20600 || length < headerSize
      || start + length > maximum || CODE_DIRECTORY_HASH_SIZES.get(hashType) !== hashSize
      || pageSize > 31 || spare2 !== 0 || specialSlotCount > 2_000_000
      || codeSlotCount > 2_000_000 || !Number.isSafeInteger(specialHashBytes)
      || !Number.isSafeInteger(codeHashBytes) || hashStart < headerSize
      || !Number.isSafeInteger(codeLimit64) || !scatterValid
      || requiredCodeSlots !== codeSlotCount
      || teamOffset >= hashStart || (teamOffset !== 0 && teamOffset < headerSize)
      || (teamOffset !== 0 && !teamIdentifier)
      || (teamIdentifier && teamOffset + teamIdentifier.length + 1 > hashStart)
      || spare3 !== 0 || (execSegmentFlags & ~0x3f1n) !== 0n
      || execSegmentEnd > BigInt(signingLimit)
      || !Number.isSafeInteger(preEncryptEnd)
      || (preEncryptOffset !== 0 && (preEncryptOffset < headerSize || preEncryptEnd > length))
      || (linkageHashType === 0
        && (linkageApplicationType !== 0 || linkageApplicationSubType !== 0
          || linkageOffset !== 0 || linkageSize !== 0))
      || (linkageHashType !== 0
        && (!linkageApplicationValid || linkageHashSize === undefined || linkageSize < 20
          || !Number.isSafeInteger(linkageEnd) || linkageOffset < headerSize
          || linkageEnd > length))
      || hashEnd > length || identifierOffset < headerSize || identifierOffset >= hashStart) return false;
    const identifier = cString(bytes, start + identifierOffset, start + length);
    if (!identifier || identifierOffset + identifier.length + 1 > hashStart) return false;
    identifiers.push(identifier);
    return hashType;
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
  const slotTypes = new Set();
  const blobOffsets = new Set();
  const blobRanges = [];
  const codeDirectoryHashTypes = new Set();
  let authorizedCodeDirectories = 0;
  for (let index = 0; index < count; index += 1) {
    const slotType = bytes.readUInt32BE(offset + 12 + index * 8);
    const blobOffset = bytes.readUInt32BE(offset + 12 + index * 8 + 4);
    if (slotTypes.has(slotType) || blobOffsets.has(blobOffset)
      || blobOffset < 12 + count * 8 || blobOffset + 8 > length) {
      return null;
    }
    slotTypes.add(slotType);
    blobOffsets.add(blobOffset);
    const blobMagic = bytes.readUInt32BE(offset + blobOffset);
    const blobLength = bytes.readUInt32BE(offset + blobOffset + 4);
    if (blobLength < 8 || blobOffset + blobLength > length) return null;
    blobRanges.push({ start: blobOffset, end: blobOffset + blobLength });
    const codeDirectorySlot = slotType === 0 || (slotType >= 0x1000 && slotType <= 0x1004);
    if (codeDirectorySlot) {
      if (blobMagic !== CODE_DIRECTORY_MAGIC) return null;
      const hashType = parseCodeDirectory(offset + blobOffset, offset + blobOffset + blobLength);
      if (!hashType || codeDirectoryHashTypes.has(hashType)) return null;
      codeDirectoryHashTypes.add(hashType);
      authorizedCodeDirectories += 1;
    } else if (blobMagic === CODE_DIRECTORY_MAGIC) {
      return null;
    } else if (SUPERBLOB_SLOT_MAGICS.has(slotType)
      && SUPERBLOB_SLOT_MAGICS.get(slotType) !== blobMagic) {
      return null;
    }
  }
  blobRanges.sort((left, right) => left.start - right.start);
  for (let index = 1; index < blobRanges.length; index += 1) {
    if (blobRanges[index - 1].end > blobRanges[index].start) return null;
  }
  return authorizedCodeDirectories > 0 && identifiers.length > 0
    ? { identifiers, validatedSize: length }
    : null;
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

function byteStringDecoder(bytes, offset, size) {
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
      cursor += 1;
    }
    if (cursor >= size || cursor === nameOffset) return { ok: false, value: null };
    const result = { ok: true, value: bytes.subarray(offset + nameOffset, offset + cursor) };
    cache.set(nameOffset, result);
    return result;
  };
}

function readULEB128(bytes, cursor, limit) {
  let value = 0n;
  let shift = 0n;
  for (let index = 0; index < 10 && cursor < limit; index += 1) {
    const byte = bytes[cursor];
    cursor += 1;
    value |= BigInt(byte & 0x7f) << shift;
    if (value > BigInt(Number.MAX_SAFE_INTEGER)) return null;
    if ((byte & 0x80) === 0) return { cursor, value: Number(value) };
    shift += 7n;
  }
  return null;
}

function skipLEB128(bytes, cursor, limit) {
  for (let index = 0; index < 10 && cursor < limit; index += 1) {
    const byte = bytes[cursor];
    cursor += 1;
    if ((byte & 0x80) === 0) return cursor;
  }
  return null;
}

function readUnsigned64LEB128(bytes, cursor, limit) {
  let value = 0n;
  let shift = 0n;
  for (let index = 0; index < 10 && cursor < limit; index += 1) {
    const byte = bytes[cursor];
    cursor += 1;
    value |= BigInt(byte & 0x7f) << shift;
    if (value > 0xffffffffffffffffn) return null;
    if ((byte & 0x80) === 0) return { cursor, value };
    shift += 7n;
  }
  return null;
}

function bindStreamPolicyImports(bytes, offset, size, kind) {
  if (size === 0) return [];
  if (offset < 0 || size < 0 || offset + size > bytes.length
    || !['regular', 'weak', 'lazy'].includes(kind)) return null;
  const limit = offset + size;
  const imports = [];
  let currentSymbol = null;
  let lazyEntryBound = false;
  let lazyEntryOpen = false;
  let cursor = offset;
  let sawDone = false;
  const retainCurrentSymbol = () => {
    if (!currentSymbol) return false;
    lazyEntryBound = true;
    if (isAppleScriptImport(currentSymbol) || VIRTUALIZATION_IMPORT.test(currentSymbol)) {
      imports.push(currentSymbol);
    }
    return true;
  };
  while (cursor < limit) {
    const instruction = bytes[cursor];
    cursor += 1;
    const opcode = instruction & 0xf0;
    const immediate = instruction & 0x0f;
    const allowed = kind === 'lazy'
      ? [0x00, 0x10, 0x20, 0x30, 0x40, 0x60, 0x70, 0x90]
      : kind === 'weak'
        ? [0x00, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xa0, 0xb0, 0xc0]
        : [0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xa0, 0xb0, 0xc0, 0xd0];
    if (!allowed.includes(opcode)) return null;
    if (opcode === 0x00) {
      if (immediate !== 0) return null;
      sawDone = true;
      if (kind !== 'lazy') {
        return bytes.subarray(cursor, limit).every((byte) => byte === 0) ? imports : null;
      }
      if (lazyEntryOpen && !lazyEntryBound) return null;
      lazyEntryOpen = false;
      lazyEntryBound = false;
      currentSymbol = null;
    } else if (opcode === 0x10 || opcode === 0x30) {
      // The immediate is the complete operand.
    } else if (opcode === 0x20 || opcode === 0x70 || opcode === 0x80) {
      const decoded = readUnsigned64LEB128(bytes, cursor, limit);
      if (!decoded) return null;
      cursor = decoded.cursor;
    } else if (opcode === 0x40) {
      if ((immediate & ~0x09) !== 0) return null;
      if (kind === 'lazy' && lazyEntryOpen) return null;
      let symbolEnd = cursor;
      while (symbolEnd < limit && bytes[symbolEnd] !== 0) symbolEnd += 1;
      if (symbolEnd === cursor || symbolEnd >= limit) return null;
      currentSymbol = bytes.subarray(cursor, symbolEnd).toString('latin1');
      if (kind === 'lazy') lazyEntryOpen = true;
      cursor = symbolEnd + 1;
    } else if (opcode === 0x50) {
      if (immediate < 1 || immediate > 3) return null;
    } else if (opcode === 0x60) {
      cursor = skipLEB128(bytes, cursor, limit);
      if (cursor === null) return null;
    } else if (opcode === 0x90) {
      if (!retainCurrentSymbol()) return null;
    } else if (opcode === 0xa0) {
      if (!retainCurrentSymbol()) return null;
      const decoded = readUnsigned64LEB128(bytes, cursor, limit);
      if (!decoded) return null;
      cursor = decoded.cursor;
    } else if (opcode === 0xb0) {
      if (!retainCurrentSymbol()) return null;
    } else if (opcode === 0xc0) {
      const count = readUnsigned64LEB128(bytes, cursor, limit);
      if (!count) return null;
      const skip = readUnsigned64LEB128(bytes, count.cursor, limit);
      if (!skip || (count.value > 0n && !retainCurrentSymbol())) return null;
      cursor = skip.cursor;
    } else if (opcode === 0xd0) {
      if (immediate === 0) {
        const decoded = readUnsigned64LEB128(bytes, cursor, limit);
        if (!decoded) return null;
        cursor = decoded.cursor;
      } else if (immediate !== 1) {
        return null;
      }
    } else {
      return null;
    }
  }
  return sawDone && !lazyEntryOpen ? imports : null;
}

function exportTrieEvidence(bytes, offset, size) {
  if (offset < 0 || size <= 0 || offset + size > bytes.length) return null;
  const decodeString = byteStringDecoder(bytes, offset, size);
  if (!decodeString) return null;
  const cache = new Map();
  const implementationOffsets = [];
  const parseNode = (nodeOffset) => {
    if (!Number.isSafeInteger(nodeOffset) || nodeOffset < 0 || nodeOffset >= size) return null;
    if (cache.has(nodeOffset)) return cache.get(nodeOffset);
    let cursor = nodeOffset;
    const terminalSize = readULEB128(bytes, offset + cursor, offset + size);
    if (!terminalSize) return null;
    cursor = terminalSize.cursor - offset;
    const terminalEnd = cursor + terminalSize.value;
    if (terminalEnd > size) return null;
    const terminal = terminalSize.value > 0;
    let reexportName = null;
    if (terminal) {
      const flags = readULEB128(bytes, offset + cursor, offset + terminalEnd);
      if (!flags || (flags.value & ~0x3f) !== 0 || (flags.value & 0x03) === 0x03
        || ((flags.value & 0x08) !== 0 && (flags.value & 0x30) !== 0)
        || (flags.value & 0x30) === 0x30) return null;
      cursor = flags.cursor - offset;
      if ((flags.value & 0x08) !== 0) {
        const ordinal = readULEB128(bytes, offset + cursor, offset + terminalEnd);
        if (!ordinal) return null;
        cursor = ordinal.cursor - offset;
        let nameEnd = cursor;
        while (nameEnd < terminalEnd && bytes[offset + nameEnd] !== 0) nameEnd += 1;
        if (nameEnd >= terminalEnd) return null;
        reexportName = bytes.subarray(offset + cursor, offset + nameEnd);
        cursor = nameEnd + 1;
      } else {
        const address = readUnsigned64LEB128(bytes, offset + cursor, offset + terminalEnd);
        if (!address) return null;
        cursor = address.cursor - offset;
        if ((flags.value & 0x03) !== 0x02) implementationOffsets.push(address.value);
        if ((flags.value & 0x20) !== 0) {
          const tableIndex = readULEB128(bytes, offset + cursor, offset + terminalEnd);
          if (!tableIndex) return null;
          cursor = tableIndex.cursor - offset;
        } else if ((flags.value & 0x10) !== 0) {
          const resolver = readUnsigned64LEB128(
            bytes,
            offset + cursor,
            offset + terminalEnd,
          );
          if (!resolver) return null;
          implementationOffsets.push(resolver.value);
          cursor = resolver.cursor - offset;
        }
      }
      if (cursor !== terminalEnd) return null;
    } else {
      cursor = terminalEnd;
    }
    if (cursor >= size) return null;
    const childCount = bytes[offset + cursor];
    cursor += 1;
    const edges = [];
    for (let index = 0; index < childCount; index += 1) {
      const edgeStart = cursor;
      const edge = decodeString(edgeStart);
      if (!edge.ok || !edge.value) return null;
      cursor += edge.value.length + 1;
      const child = readULEB128(bytes, offset + cursor, offset + size);
      if (!child || child.value === 0 || child.value >= size) return null;
      cursor = child.cursor - offset;
      edges.push({
        child: child.value,
        end: edgeStart + edge.value.length,
        start: edgeStart,
        value: edge.value,
      });
    }
    const record = { edges, reexportName, terminal };
    cache.set(nodeOffset, record);
    return record;
  };

  const active = new Set();
  const imports = [];
  const ranges = [];
  let remainingVisits = Math.max(1, size * 4);
  let remainingPrefixBytes = Math.max(1, size * 4);
  const path = [];
  const walk = (nodeOffset, pathLength, depth) => {
    if (depth > 512 || active.has(nodeOffset) || remainingVisits <= 0) return null;
    remainingVisits -= 1;
    const node = parseNode(nodeOffset);
    if (!node) return null;
    active.add(nodeOffset);
    let hasTerminal = node.terminal;
    let usesPathAsImport = false;
    if (node.reexportName !== null) {
      let importBytes = node.reexportName;
      if (importBytes.length === 0) {
        remainingPrefixBytes -= pathLength;
        if (remainingPrefixBytes < 0) return null;
        importBytes = Buffer.concat(path, pathLength);
      }
      if (importBytes.length === 0) return null;
      const isASCII = importBytes.every((byte) => byte >= 0x20 && byte <= 0x7e);
      const importName = isASCII ? importBytes.toString('ascii') : null;
      if (importName && (isAppleScriptImport(importName) || VIRTUALIZATION_IMPORT.test(importName))) {
        imports.push(importName);
      }
      usesPathAsImport = node.reexportName.length === 0;
    }
    for (const edge of node.edges) {
      path.push(edge.value);
      const child = walk(edge.child, pathLength + edge.value.length, depth + 1);
      path.pop();
      if (!child?.hasTerminal) return null;
      if (!child.usesPathAsImport) ranges.push({ start: edge.start, end: edge.end });
      hasTerminal = true;
      usesPathAsImport ||= child.usesPathAsImport;
    }
    active.delete(nodeOffset);
    return { hasTerminal, usesPathAsImport };
  };
  const root = walk(0, 0, 0);
  return root === null ? null : { implementationOffsets, imports, ranges };
}

function chainedStartsSegmentCount(bytes, offset, startsOffset, importsOffset, endian) {
  if (startsOffset < 28 || startsOffset >= importsOffset || offset + importsOffset > bytes.length) {
    return null;
  }
  const startsSize = importsOffset - startsOffset;
  const startsBase = offset + startsOffset;
  if (startsSize < 4) return null;
  const segmentCount = unsignedInteger(bytes, startsBase, 4, endian);
  if (segmentCount === null || segmentCount > 4096 || 4 + segmentCount * 4 > startsSize) return null;
  const tableEnd = 4 + segmentCount * 4;
  const ranges = [];
  const segmentOffsets = Array(segmentCount).fill(null);
  let commonPointerFormat = null;
  let commonMaximumPointer = null;
  for (let index = 0; index < segmentCount; index += 1) {
    const infoOffset = unsignedInteger(bytes, startsBase + 4 + index * 4, 4, endian);
    if (infoOffset === null) return null;
    if (infoOffset === 0) continue;
    if (infoOffset < tableEnd || infoOffset + 22 > startsSize) return null;
    const infoBase = startsBase + infoOffset;
    const infoSize = unsignedInteger(bytes, infoBase, 4, endian);
    const pageSize = unsignedInteger(bytes, infoBase + 4, 2, endian);
    const pointerFormat = unsignedInteger(bytes, infoBase + 6, 2, endian);
    const segmentOffset = unsignedBigInteger(bytes, infoBase + 8, endian);
    const maximumPointer = unsignedInteger(bytes, infoBase + 16, 4, endian);
    const pageCount = unsignedInteger(bytes, infoBase + 20, 2, endian);
    if (infoSize === null || pageSize === null || ![0x1000, 0x4000].includes(pageSize)
      || pointerFormat === null || !CHAINED_POINTER_FORMATS.has(pointerFormat)
      || segmentOffset === null || maximumPointer === null
      || pageCount === null || pageCount > 65_536) return null;
    // Match dyld MachOAnalyzer::validChainedFixupsInfo across nonempty segment records.
    if (commonPointerFormat === null) commonPointerFormat = pointerFormat;
    if (pointerFormat !== commonPointerFormat) return null;
    if (maximumPointer !== 0) {
      if (commonMaximumPointer === null) commonMaximumPointer = maximumPointer;
      if (maximumPointer !== commonMaximumPointer) return null;
    }
    segmentOffsets[index] = segmentOffset;
    const pageStartsEnd = 22 + pageCount * 2;
    if (infoSize < pageStartsEnd || (infoSize - pageStartsEnd) % 2 !== 0
      || infoOffset + infoSize > startsSize) return null;
    const totalStartCount = (infoSize - 22) / 2;
    const validatedOverflowLists = new Set();
    let remainingOverflowEntries = Math.max(1, totalStartCount * 4);
    for (let page = 0; page < pageCount; page += 1) {
      const pageStart = unsignedInteger(bytes, infoBase + 22 + page * 2, 2, endian);
      if (pageStart === null || pageStart === 0xffff) continue;
      if ((pageStart & 0x8000) === 0) {
        if (pageStart >= pageSize) return null;
        continue;
      }
      let overflowIndex = pageStart & 0x7fff;
      if (overflowIndex < pageCount || overflowIndex >= totalStartCount) return null;
      if (validatedOverflowLists.has(overflowIndex)) continue;
      const overflowStart = overflowIndex;
      let lastStart = -1;
      for (;;) {
        remainingOverflowEntries -= 1;
        if (remainingOverflowEntries < 0) return null;
        const chainStart = unsignedInteger(
          bytes,
          infoBase + 22 + overflowIndex * 2,
          2,
          endian,
        );
        const start = chainStart === null ? null : chainStart & 0x7fff;
        if (start === null || start >= pageSize || start <= lastStart) return null;
        lastStart = start;
        overflowIndex += 1;
        if ((chainStart & 0x8000) !== 0) break;
        if (overflowIndex >= totalStartCount) return null;
      }
      validatedOverflowLists.add(overflowStart);
    }
    ranges.push({ start: infoOffset, end: infoOffset + infoSize });
  }
  ranges.sort((left, right) => left.start - right.start);
  for (let index = 1; index < ranges.length; index += 1) {
    if (ranges[index - 1].end > ranges[index].start) return null;
  }
  return { segmentCount, segmentOffsets };
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
    || importsOffset === null || importsOffset < 28 || importsOffset > size
    || symbolsOffset === null || symbolsOffset < 28 || symbolsOffset > size
    || importsCount === null || importsCount > 2_000_000
    || (importsCount > 0 && (importsOffset === size || symbolsOffset === size))
    || ![1, 2, 3].includes(importsFormat) || ![0, 1].includes(symbolsFormat)) return null;
  const starts = chainedStartsSegmentCount(bytes, offset, startsOffset, importsOffset, endian);
  if (!starts) return null;
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
  return { imports, segmentCount: starts.segmentCount, segmentOffsets: starts.segmentOffsets };
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
  let chainedSegmentCount = null;
  let chainedSegmentOffsets = null;
  const policyStringExclusions = [];
  const ignoredPolicyStringRanges = [];
  const exportImplementationOffsets = [];
  let sawCodeSignature = false;
  let sawDyldInfo = false;
  let sawExportsTrie = false;
  let sawSegment = false;
  const segments = [];
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
      const virtualSize32 = is64BitSegment
        ? null
        : unsignedInteger(bytes, cursor + 28, 4, format.endian);
      const virtualAddress32 = is64BitSegment
        ? null
        : unsignedInteger(bytes, cursor + 24, 4, format.endian);
      const virtualSize = is64BitSegment
        ? unsignedBigInteger(bytes, cursor + 32, format.endian)
        : virtualSize32 === null ? null : BigInt(virtualSize32);
      const virtualAddress = is64BitSegment
        ? unsignedBigInteger(bytes, cursor + 24, format.endian)
        : virtualAddress32 === null ? null : BigInt(virtualAddress32);
      const rawName = bytes.subarray(cursor + 8, cursor + 24);
      const nameEnd = rawName.indexOf(0);
      const name = rawName.subarray(0, nameEnd < 0 ? rawName.length : nameEnd).toString('ascii');
      if (sectionCount === null || sectionCount > 4096
        || minimumSize + sectionCount * sectionSize !== commandSize
        || fileOffset === null || fileSize === null || fileOffset + fileSize > size
        || virtualAddress === null || virtualSize === null
        || virtualAddress + virtualSize > 0xffffffffffffffffn) return null;
      sawSegment = true;
      segments.push({ fileOffset, fileSize, name, virtualAddress, virtualSize });
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
    } else if (baseCommand === 0x22) {
      if (commandSize !== 48 || sawDyldInfo) return null;
      sawDyldInfo = true;
      const ranges = [];
      for (let field = 0; field < 5; field += 1) {
        const dataOffset = unsignedInteger(bytes, cursor + 8 + field * 8, 4, format.endian);
        const dataSize = unsignedInteger(bytes, cursor + 12 + field * 8, 4, format.endian);
        if (dataOffset === null || dataSize === null || dataOffset + dataSize > size) return null;
        ranges.push({ offset: dataOffset, size: dataSize });
      }
      for (const [field, kind] of [[1, 'regular'], [2, 'weak'], [3, 'lazy']]) {
        const range = ranges[field];
        if (range.size === 0) continue;
        const dyldImports = bindStreamPolicyImports(bytes, offset + range.offset, range.size, kind);
        if (!dyldImports) return null;
        imports.push(...dyldImports);
      }
      const exportRange = ranges[4];
      if (exportRange.size > 0) {
        const exportEvidence = exportTrieEvidence(
          bytes,
          offset + exportRange.offset,
          exportRange.size,
        );
        if (!exportEvidence) return null;
        exportImplementationOffsets.push(...exportEvidence.implementationOffsets);
        imports.push(...exportEvidence.imports);
        ignoredPolicyStringRanges.push(...exportEvidence.ranges.map((range) => ({
          start: exportRange.offset + range.start,
          end: exportRange.offset + range.end,
        })));
      }
    } else if (baseCommand === 0x33) {
      if (commandSize !== 16 || sawExportsTrie) return null;
      sawExportsTrie = true;
      const trieOffset = unsignedInteger(bytes, cursor + 8, 4, format.endian);
      const trieSize = unsignedInteger(bytes, cursor + 12, 4, format.endian);
      if (trieOffset === null || trieSize === null || trieOffset + trieSize > size) return null;
      if (trieSize > 0) {
        const exportEvidence = exportTrieEvidence(bytes, offset + trieOffset, trieSize);
        if (!exportEvidence) return null;
        exportImplementationOffsets.push(...exportEvidence.implementationOffsets);
        imports.push(...exportEvidence.imports);
        ignoredPolicyStringRanges.push(...exportEvidence.ranges.map((range) => ({
          start: trieOffset + range.start,
          end: trieOffset + range.end,
        })));
      }
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
      const chainedFixups = chainedFixupPolicyImports(
        bytes,
        offset + fixupsOffset,
        fixupsSize,
        format.endian,
      );
      if (!chainedFixups) return null;
      chainedSegmentCount = chainedFixups.segmentCount;
      chainedSegmentOffsets = chainedFixups.segmentOffsets;
      imports.push(...chainedFixups.imports);
    }
    cursor += commandSize;
  }
  if (cursor !== commandLimit || !sawSegment || !symbolTable) return null;
  if (chainedSegmentCount !== null && chainedSegmentCount !== segments.length) {
    const linkeditIndex = segments.findIndex((segment) => segment.name === '__LINKEDIT');
    const expectedCount = linkeditIndex + 1;
    const missingCount = expectedCount - chainedSegmentCount;
    const insertedSegments = missingCount > 0
      ? segments.slice(linkeditIndex - missingCount, linkeditIndex)
      : [];
    if (linkeditIndex < 0 || chainedSegmentCount > expectedCount || missingCount <= 0
      || insertedSegments.length !== missingCount
      || insertedSegments.some((segment) => segment.virtualSize !== 0n)) return null;
  }
  if (chainedSegmentOffsets?.some((segmentOffset) => segmentOffset !== null)) {
    const headerSegment = segments.find((segment) => segment.fileOffset === 0 && segment.fileSize > 0);
    if (!headerSegment) return null;
    for (const [index, segmentOffset] of chainedSegmentOffsets.entries()) {
      if (segmentOffset === null) continue;
      const segment = segments[index];
      if (!segment) return null;
      const expectedOffset = BigInt.asUintN(
        64,
        segment.virtualAddress - headerSegment.virtualAddress,
      );
      if (segmentOffset !== expectedOffset) return null;
    }
  }
  if (exportImplementationOffsets.length > 0) {
    const headerSegment = segments.find((segment) => segment.fileOffset === 0 && segment.fileSize > 0);
    if (!headerSegment) return null;
    for (const value of exportImplementationOffsets) {
      const signedOffset = value >= 0x8000000000000000n ? value - 0x10000000000000000n : value;
      const address = headerSegment.virtualAddress + signedOffset;
      const mapped = segments.some((segment) => (
        segment.virtualSize > 0n && address >= segment.virtualAddress
        && address < segment.virtualAddress + segment.virtualSize
      ));
      if (!mapped) return null;
    }
  }
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
    if (!slice || slice.cpuType !== record.cpuType
      || (slice.cpuSubtype & CPU_SUBTYPE_VALUE_MASK)
        !== (record.cpuSubtype & CPU_SUBTYPE_VALUE_MASK)) return null;
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
