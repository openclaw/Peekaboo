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
const sourceContractFiles = [path.resolve('scripts/test-background-computer-use.sh')];
const sourceCliDocsFiles = [path.resolve('scripts/release-binaries.sh')];
const staleCliPatterns = [
  [/peekaboo capture --output\b/, 'use `peekaboo see --no-elements --path` or `peekaboo capture live --path`'],
  [/peekaboo capture --window-focused\b/, 'use `peekaboo see --no-elements --mode frontmost`'],
  [/--press-return\b/, 'chain `peekaboo press Return`'],
  [/peekaboo image\b/, 'use `peekaboo see --no-elements`'],
  [/peekaboo hotkey\b/, 'use `peekaboo press` with xdotool chord syntax'],
  [/peekaboo swipe\b/, 'use `peekaboo drag`'],
  [/peekaboo inspect-ui\b/, 'use `peekaboo see --tree --no-screenshot`'],
  [/peekaboo perform-action\b/, 'use `peekaboo action`'],
  [/peekaboo list\b/, 'use noun-based `app list`, `window list`, or `screen list`'],
  [/--(?:from|to)-coords\b/, 'pass coordinates directly to `--from` or `--to`'],
  [/--max-depth\b/, 'use `--depth`'],
  [/peekaboo type[^\n]*--(?:return|escape|delete|tab)\b/, 'chain `peekaboo press` for key input'],
  [/--delay-ms\b/, 'use `--delay`'],
  [/--timeout-seconds\b/, 'use `--timeout` with an `ms` or `s` suffix'],
  [/--focus-timeout-seconds\b/, 'use `--focus-timeout` with an `ms` or `s` suffix'],
  [/--restore-delay-ms\b/, 'use `--restore-delay` with an `ms` or `s` suffix'],
  [/--hold-duration\b/, 'use `--hold` with an `ms` or `s` suffix'],
  [/--global-coords\b/, 'use `--global`'],
  [/--coords\b/, 'use `--at`'],
  [/--poll-interval-ms\b/, 'use `--poll-interval` with an `ms` or `s` suffix'],
  [/--wait-seconds\b/, 'use `--wait` with an `ms` or `s` suffix'],
  [/--idle-timeout-seconds\b/, 'use `--idle-timeout` with an `ms` or `s` suffix'],
  [/--heartbeat-sec\b/, 'use `--heartbeat` with an `ms` or `s` suffix'],
  [/--quiet-ms\b/, 'use `--quiet` with an `ms` or `s` suffix'],
  [/--diff-budget-ms\b/, 'use `--diff-budget` with an `ms` or `s` suffix'],
  [/--autoclean-minutes\b/, 'use `--autoclean` with an `ms` or `s` suffix'],
  [/--every-ms\b/, 'use `--every` with an `ms` or `s` suffix'],
  [/--start-ms\b/, 'use `--start` with an `ms` or `s` suffix'],
  [/--end-ms\b/, 'use `--end` with an `ms` or `s` suffix'],
  [/--pre-roll-ms\b/, 'use `--pre-roll` with an `ms` or `s` suffix'],
  [/--post-roll-ms\b/, 'use `--post-roll` with an `ms` or `s` suffix'],
  [/--repeat\b/, 'use `--count`'],
  [/--label\b/, 'use positional query text or `--on`'],
  [/--ticks\b/, 'use `--amount`'],
  [/docs\/commands\/run\.md/, 'link to the current command that owns the workflow'],
  [/peekaboo space (?:current|where-is)\b/, 'use `peekaboo space list --detailed`'],
  [/--space-switch\s+(?:always|never)\b/, 'use boolean `--space-switch`'],
  [/--(?:move-here|no-verify)\b/, 'use `--bring-to-current-space` or `--verify`'],
  [/peekaboo space list --all\b/, 'use `peekaboo space list --detailed`'],
  [/peekaboo space switch[^\n]*--no-wait\b/, 'remove the retired `--no-wait` flag'],
  [/peekaboo (?:capture|drag|move)[^\n]*--duration\s+\d+(?:\.\d+)?(?:\s|$)/,
    'add an explicit `ms` or `s` duration suffix'],
  [/peekaboo (?:click|press|type)[^\n]*--(?:delay|hold|wait-for)\s+\d+(?:\.\d+)?(?:\s|$)/,
    'add an explicit `ms` or `s` timing suffix'],
  [/--(?:on|from|to)\s+[`"']?[BTMS]\d+\b/, 'use an opaque element ID copied from current output'],
  [/element IDs?\s+(?:(?:such as|like|for example)\s+)?[`"']?[BTMS]\d+\b/i,
    'describe element IDs as opaque'],
];
const staleHarnessPatterns = [
  [/^\s*hotkey\s/m, 'use `press`'],
  [/^\s*inspect-ui\s/m, 'use `see --tree --no-screenshot`'],
  [/^\s*image\s/m, 'use `see --no-elements`'],
  [/^\s*perform-action\s/m, 'use `action`'],
  [/^\s*list\s+(?:apps|windows|screens)\b/m, 'use noun-based inventory commands'],
  [/\bapp launch[^\n]*--wait-until-ready\b/, 'use `app launch --wait-ready`'],
  [/--coords\b/, 'use `--at`'],
  [/--duration\s+\d+(?:\.\d+)?(?:\s|\\|$)/, 'add an explicit `ms` or `s` duration suffix'],
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
    await checkLocalLinks(file, text);

    for (const line of text.split('\n')) {
      if (/peekaboo click\b.*--at\b/.test(line) &&
          (!/--window-id\b/.test(line) || !/--snapshot\b/.test(line))) {
        failures.push(`${file}: coordinate click must include a fresh snapshot and exact --window-id target`);
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

async function checkLocalLinks(file, text) {
  const links = text.matchAll(/!?\[[^\]]*\]\(([^)\s]+)(?:\s+['"][^)]*)?\)/g);
  for (const match of links) {
    const rawTarget = match[1];
    if (/^(?:https?:|mailto:|#)/.test(rawTarget)) continue;
    const target = rawTarget.split('#', 1)[0].split('?', 1)[0];
    if (!target) continue;
    const resolved = path.resolve(path.dirname(file), decodeURIComponent(target));
    try {
      await fs.access(resolved);
    } catch {
      failures.push(`${file}: broken local link ${rawTarget}`);
    }
  }
}

function shouldCheckCurrentCliExamples(file) {
  const relative = path.relative(process.cwd(), file);
  if (relative === 'README.md') return true;
  if ([
    'docs/quickstart.md',
    'docs/automation.md',
    'docs/cli-command-reference.md',
    'docs/focus.md',
    'docs/testing/background-computer-use.md',
    'docs/testing/tools.md',
  ].includes(relative)) return true;
  if (relative === 'docs/commands/README.md') return true;
  if (relative.startsWith('docs/commands/') && relative.endsWith('.md')) return true;
  return false;
}

async function checkSourceContractFile(file) {
  const text = await fs.readFile(file, 'utf8');
  for (const [pattern, replacement] of staleHarnessPatterns) {
    if (pattern.test(text)) {
      failures.push(`${file}: stale v4 harness form ${pattern}; ${replacement}`);
    }
  }
}

async function checkSourceCliDocsFile(file) {
  const text = await fs.readFile(file, 'utf8');
  for (const [pattern, replacement] of staleCliPatterns) {
    if (pattern.test(text)) {
      failures.push(`${file}: stale generated CLI docs ${pattern}; ${replacement}`);
    }
  }
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
for (const file of sourceContractFiles) {
  await checkSourceContractFile(file);
}
for (const file of sourceCliDocsFiles) {
  await checkSourceCliDocsFile(file);
}

if (failures.length) {
  console.error('Docs lint failures:');
  failures.forEach(f => console.error(' -', f));
  process.exit(1);
}

console.log('docs-lint: ok');
