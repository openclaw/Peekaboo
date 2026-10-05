#!/usr/bin/env node

/**
 * Lists documentation summaries so agents can see what to read before coding.
 * The format mirrors the helper from steipete/agent-scripts but tolerates
 * legacy files that lack front matter by falling back to the first heading.
 */

import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const DOCS_DIR = join(__dirname, '..', 'docs');

const EXCLUDED_DIRS = new Set(['archive', 'research']);

function walkMarkdownFiles(dir, base = dir) {
  const entries = readdirSync(dir, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    if (entry.name.startsWith('.')) continue;
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (EXCLUDED_DIRS.has(entry.name)) {
        continue;
      }
      files.push(...walkMarkdownFiles(fullPath, base));
    } else if (entry.isFile() && entry.name.toLowerCase().endsWith('.md')) {
      files.push(relative(base, fullPath));
    }
  }

  return files.sort((a, b) => a.localeCompare(b));
}

function extractMetadata(fullPath) {
  const content = readFileSync(fullPath, 'utf8');
  const issues = [];
  const readWhen = [];

  if (!content.startsWith('---')) {
    const summary = deriveHeadingSummary(content) ?? '(add summary front matter)';
    issues.push('front matter missing');
    return { summary, readWhen, issues };
  }

  const endIndex = content.indexOf('\n---', 3);
  if (endIndex === -1) {
    const summary = deriveHeadingSummary(content) ?? '(front matter incomplete)';
    issues.push('unterminated front matter');
    return { summary, readWhen, issues };
  }

  const frontMatter = content.slice(3, endIndex).trim();
  const lines = frontMatter.split('\n');

  let summaryLine = null;
  let collectingReadWhen = false;

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (line.startsWith('summary:')) {
      summaryLine = line.slice('summary:'.length).trim();
      collectingReadWhen = false;
      continue;
    }
    if (line.startsWith('read_when:')) {
      collectingReadWhen = true;
      const inline = line.slice('read_when:'.length).trim();
      if (inline.startsWith('[') && inline.endsWith(']')) {
        collectingReadWhen = false;
        try {
          let parsed;
          try {
            parsed = JSON.parse(inline);
          } catch {
            // Retain the existing simple single-quoted array support without
            // rewriting apostrophes inside otherwise valid JSON strings.
            parsed = JSON.parse(inline.replace(/'/g, '"'));
          }
          if (Array.isArray(parsed)) {
            for (const item of parsed) {
              if (typeof item === 'string' && item.trim().length > 0) {
                readWhen.push(item.trim());
              }
            }
          }
        } catch {
          issues.push('read_when inline array malformed');
        }
      }
      continue;
    }

    if (collectingReadWhen) {
      if (line.startsWith('- ')) {
        const hint = line.slice(2).trim();
        if (hint.length > 0) {
          readWhen.push(hint);
        }
      } else if (line.length === 0) {
        continue;
      } else {
        collectingReadWhen = false;
      }
    }
  }

  if (!summaryLine) {
    issues.push('summary key missing');
  }

  const summaryValue = normalizeSummary(summaryLine);
  if (!summaryValue) {
    issues.push('summary is empty');
  }

  const summary =
    summaryValue ?? deriveHeadingSummary(content.slice(endIndex + 4)) ?? '(add summary front matter)';

  return { summary, readWhen, issues };
}

function normalizeSummary(value) {
  if (!value) return null;
  const trimmed = value.replace(/^['"]|['"]$/g, '').replace(/\s+/g, ' ').trim();
  return trimmed.length > 0 ? trimmed : null;
}

function deriveHeadingSummary(content) {
  const lines = content.split('\n');
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (line.startsWith('#')) {
      const heading = line.replace(/^#+\s*/, '').trim();
      if (heading.length > 0) {
        return heading;
      }
    }
    if (line.length > 0) {
      // Bail once we hit real content to avoid scanning entire file.
      break;
    }
  }
  return null;
}

console.log('Listing documentation summaries (docs/):\n');

const markdownFiles = walkMarkdownFiles(DOCS_DIR);

for (const relativePath of markdownFiles) {
  const fullPath = join(DOCS_DIR, relativePath);
  const { summary, readWhen, issues } = extractMetadata(fullPath);
  const suffix = issues.length > 0 ? ` [${issues.join(', ')}]` : '';
  console.log(`${relativePath} - ${summary}${suffix}`);
  if (readWhen.length > 0) {
    console.log(`  Read when: ${readWhen.join('; ')}`);
  }
}

console.log('\nIf a doc is missing front matter, add:');
console.log('---');
console.log("summary: 'Short imperative summary'");
console.log('read_when:');
console.log('  - condition 1');
console.log('  - condition 2');
console.log('---');
console.log('before the first heading so the helper can surface it contextually.');
