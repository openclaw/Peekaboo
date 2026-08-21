#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

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

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let sourceCommit = null;
if (process.argv.length === 4 && process.argv[2] === '--source-commit' && /^[0-9a-f]{40}$/.test(process.argv[3])) {
  sourceCommit = process.argv[3];
} else if (process.argv.length !== 2) {
  throw new Error('Usage: controller-source-manifest.mjs [--source-commit SHA]');
}

function validateRelativePath(candidate) {
  if (typeof candidate !== 'string' || !/^[A-Za-z0-9_./+-]+$/.test(candidate) ||
      candidate.includes('\\') || candidate.startsWith('/') ||
      path.posix.normalize(candidate) !== candidate || candidate.split('/').some((part) => !part || part === '.' || part === '..')) {
    throw new Error(`controller source path is unsafe: ${candidate}`);
  }
  return candidate;
}

function readSource(relativePath) {
  validateRelativePath(relativePath);
  if (!sourceCommit) return readFileSync(path.join(root, relativePath));
  const result = spawnSync('/usr/bin/git', ['show', `${sourceCommit}:${relativePath}`], {
    cwd: root,
    encoding: null,
    maxBuffer: 64 * 1024 * 1024
  });
  if (result.status !== 0) throw new Error(`could not read ${relativePath} from ${sourceCommit}`);
  return result.stdout;
}

const catalogRelativePath = 'scripts/multi-target-certification-catalog.json';
const catalogBytes = readSource(catalogRelativePath);
const catalog = JSON.parse(catalogBytes.toString('utf8'));
const manifest = catalog.current_build_source?.controller_source_manifest;
if (!Array.isArray(manifest) || manifest.length === 0) throw new Error('controller source manifest missing');
const seenPaths = new Set();
for (const entry of manifest) {
  if (!entry || Object.keys(entry).sort().join(',') !== 'path,sha256' ||
      !/^[0-9a-f]{64}$/.test(entry.sha256 ?? '')) {
    throw new Error('controller source manifest entry is invalid');
  }
  validateRelativePath(entry.path);
  if (seenPaths.has(entry.path)) throw new Error(`duplicate controller source path: ${entry.path}`);
  seenPaths.add(entry.path);
  const bytes = readSource(entry.path);
  if (createHash('sha256').update(bytes).digest('hex') !== entry.sha256) {
    throw new Error(`controller source changed: ${entry.path}`);
  }
}
process.stdout.write(`${JSON.stringify({
  version: 1,
  catalog_path: catalogRelativePath,
  catalog_sha256: createHash('sha256').update(catalogBytes).digest('hex'),
  aggregate_sha256: aggregateSHA256('certification-controller-source-manifest', manifest),
  files: manifest
})}\n`);
