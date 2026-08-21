#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { lstat, readFile, readdir, readlink } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const rootArgument = process.argv[2];
if (!rootArgument || process.argv.length !== 3) {
  console.error('Usage: scripts/artifact-tree-manifest.mjs <path>');
  process.exit(2);
}

const root = path.resolve(rootArgument);

function bytewiseCompare(left, right) {
  return Buffer.compare(Buffer.from(left), Buffer.from(right));
}

function modeString(mode) {
  return (mode & 0o7777).toString(8).padStart(4, '0');
}

async function sha256(filePath) {
  return createHash('sha256').update(await readFile(filePath)).digest('hex');
}

const entries = [];

async function visit(absolutePath, relativePath) {
  const metadata = await lstat(absolutePath);
  const displayPath = relativePath || '.';
  if (metadata.isSymbolicLink()) {
    entries.push({ path: displayPath, type: 'symlink', mode: modeString(metadata.mode), target: await readlink(absolutePath) });
    return;
  }
  if (metadata.isDirectory()) {
    entries.push({ path: displayPath, type: 'directory', mode: modeString(metadata.mode) });
    const names = await readdir(absolutePath);
    names.sort(bytewiseCompare);
    for (const name of names) {
      await visit(path.join(absolutePath, name), relativePath ? `${relativePath}/${name}` : name);
    }
    return;
  }
  if (metadata.isFile()) {
    entries.push({
      path: displayPath,
      type: 'file',
      mode: modeString(metadata.mode),
      size: metadata.size,
      sha256: await sha256(absolutePath)
    });
    return;
  }
  throw new Error(`Unsupported artifact entry type: ${displayPath}`);
}

await visit(root, '');
process.stdout.write(`${JSON.stringify({ version: 1, entries })}\n`);
