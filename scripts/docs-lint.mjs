#!/usr/bin/env node
/**
 * Minimal docs linter: verifies every Markdown file in docs/ has front matter
 * with a summary and at least one read_when entry.
 */
import { promises as fs } from 'fs';
import path from 'path';

const docsRoot = path.resolve('docs');
const failures = [];
const extraMarkdownFiles = [path.resolve('README.md')];
const skillMarkdownFiles = [path.resolve('skills/peekaboo/SKILL.md')];
const staleCliPatterns = [
  [/peekaboo capture --output\b/, 'use `peekaboo image --path` or `peekaboo capture live --path`'],
  [/peekaboo capture --window-focused\b/, 'use `peekaboo image --mode frontmost`'],
  [/--press-return\b/, 'use `--return`'],
  [/--delay-ms\b/, 'use `--delay`'],
  [/--repeat\b/, 'use `--count`'],
  [/--label\b/, 'use positional query text or `--on`'],
  [/--at\b/, 'use `--coords`'],
  [/--ticks\b/, 'use `--amount`'],
  [/--(?:on|from|to)\s+[`"']?[BTMS]\d+\b/, 'use an opaque element ID copied from current output'],
  [/element IDs?[^\n]*[`"']?[BTMS]\d+\b/i, 'describe element IDs as opaque'],
];
const staleDocsPatterns = [
  [/mcp-capture-meta/i, 'remove stale native MCP capture metadata references'],
  [/capture, shell, agent/i, 'native MCP catalog does not expose capture or shell'],
];

async function walk(dir) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await walk(full);
    } else if (entry.isFile() && entry.name.endsWith('.md')) {
      await checkFile(full);
    }
  }
}

async function checkFile(file) {
  const text = await fs.readFile(file, 'utf8');
  const trimmed = text.trimStart();
  const requiresFrontMatter = path.relative(process.cwd(), file) !== 'README.md';
  if (!trimmed.startsWith('---')) {
    if (requiresFrontMatter) {
      failures.push(`${file}: missing front matter start`);
      return;
    }
  } else if (requiresFrontMatter) {
    const end = trimmed.indexOf('\n---', 3);
    if (end === -1) {
      failures.push(`${file}: missing front matter end delimiter`);
      return;
    }
    const header = trimmed.slice(3, end).split('\n').map(l => l.trim());
    const hasSummary = header.some(l => l.startsWith('summary:') && l.replace('summary:', '').trim().length > 0);
    const readWhenStart = header.findIndex(l => l.startsWith('read_when:'));
    let hasReadWhen = false;
    if (readWhenStart !== -1) {
      for (let i = readWhenStart + 1; i < header.length; i++) {
        const line = header[i];
        if (!line.startsWith('-') && !line.startsWith('#') && !line.startsWith('summary:') && !line.startsWith('read_when:') && line.length) break;
        if (line.startsWith('-')) {
          hasReadWhen = true;
          break;
        }
      }
    }
    if (!hasSummary) failures.push(`${file}: summary missing or empty`);
    if (readWhenStart === -1) failures.push(`${file}: read_when missing`);
    else if (!hasReadWhen) failures.push(`${file}: read_when has no entries`);
  }

  if (shouldCheckCurrentCliExamples(file)) {
    for (const [pattern, replacement] of staleCliPatterns) {
      if (pattern.test(text)) {
        failures.push(`${file}: stale CLI example ${pattern}; ${replacement}`);
      }
    }
  }

  if (shouldCheckCurrentDocsDrift(file)) {
    for (const [pattern, replacement] of staleDocsPatterns) {
      if (pattern.test(text)) {
        failures.push(`${file}: stale docs ${pattern}; ${replacement}`);
      }
    }
  }
}

function shouldCheckCurrentCliExamples(file) {
  const relative = path.relative(process.cwd(), file);
  if (relative === 'README.md') return true;
  if (relative === 'docs/quickstart.md' || relative === 'docs/automation.md') return true;
  if (relative === 'docs/commands/README.md') return true;
  if (relative.startsWith('docs/commands/') && relative.endsWith('.md')) return true;
  return false;
}

function shouldCheckCurrentDocsDrift(file) {
  const relative = path.relative(process.cwd(), file);
  return [
    'docs/commands/README.md',
    'docs/manual-testing.md',
    'docs/testing/tools.md',
  ].includes(relative);
}

async function checkSkillFile(file) {
  const text = await fs.readFile(file, 'utf8');
  const trimmed = text.trimStart();
  if (!trimmed.startsWith('---')) {
    failures.push(`${file}: missing front matter start`);
    return;
  }

  const end = trimmed.indexOf('\n---', 3);
  if (end === -1) {
    failures.push(`${file}: missing front matter end delimiter`);
    return;
  }

  const header = trimmed.slice(3, end);
  const description = header.match(/^description:\s*(.+)$/m);
  if (!description) {
    failures.push(`${file}: description missing`);
    return;
  }

  const value = description[1].trim();
  if (!/^(['"]).*\1$/.test(value)) {
    failures.push(`${file}: description must be quoted YAML`);
  }
}

await walk(docsRoot);
for (const file of extraMarkdownFiles) {
  await checkFile(file);
}
for (const file of skillMarkdownFiles) {
  await checkSkillFile(file);
}

if (failures.length) {
  console.error('Docs lint failures:');
  failures.forEach(f => console.error(' -', f));
  process.exit(1);
}

console.log('docs-lint: ok');
