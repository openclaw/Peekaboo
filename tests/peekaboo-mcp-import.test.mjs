import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

function fixture(t) {
  const root = mkdtempSync(path.join(tmpdir(), 'peekaboo-mcp-import-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const wrapper = path.join(root, 'wrapper.mjs');
  const alias = path.join(root, 'wrapper-alias.mjs');
  const marker = path.join(root, 'started');
  copyFileSync(process.env.PEEKABOO_MCP_SOURCE || new URL('../peekaboo-mcp.js', import.meta.url), wrapper);
  symlinkSync(wrapper, alias);
  symlinkSync(wrapper, path.join(root, '-'));
  writeFileSync(path.join(root, 'peekaboo'), '#!/bin/sh\nprintf "started\\n" >> "$PEEKABOO_IMPORT_MARKER"\nexit 0\n', { mode: 0o755 });
  const importCode = `const {PeekabooMCPWrapper} = await import(${JSON.stringify(pathToFileURL(wrapper).href)}); console.log(typeof PeekabooMCPWrapper);`;
  const dynamicCode = `void import(${JSON.stringify(pathToFileURL(wrapper).href)}).then(({PeekabooMCPWrapper}) => console.log(typeof PeekabooMCPWrapper));`;
  return {
    root, wrapper, alias, marker, importCode, dynamicCode,
    run: (args, input) => spawnSync(process.execPath, args, {
      cwd: root, input, encoding: 'utf8', timeout: 3000,
      env: { ...process.env, PEEKABOO_IMPORT_MARKER: marker },
    }),
  };
}

function imported(result, f, stdout = 'function\n') {
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, 0, result.stderr);
  if (Array.isArray(stdout)) assert.deepEqual(result.stdout.split('\n').sort(), [...stdout, ''].sort());
  else assert.equal(result.stdout, stdout);
  assert.equal(result.stderr, '');
  assert.equal(existsSync(f.marker), false, 'Import must not launch even the inert sibling');
}

for (const variant of ['none', 'option', 'missing', 'not-directory', 'exact', 'symlink']) {
  test(`ESM eval imports without starting a server: ${variant} argument`, (t) => {
    const f = fixture(t);
    const values = { option: '--client-name=fixture', missing: 'missing.js', 'not-directory': path.join(f.wrapper, 'child'), exact: f.wrapper, symlink: f.alias };
    imported(f.run(['--input-type=module', '--eval', f.importCode, ...(variant === 'none' ? [] : ['--', values[variant]])]), f);
  });
}

for (const mode of ['cjs-eval', 'attached-eval', 'print', 'print-eval']) {
  test(`${mode} treats a matching wrapper path as a program argument`, (t) => {
    const f = fixture(t);
    const args = mode === 'attached-eval' ? [`--eval=${f.dynamicCode}`]
      : [mode === 'cjs-eval' ? '-e' : mode === 'print' ? '--print' : '-pe', f.dynamicCode];
    imported(f.run([...args, '--', f.wrapper]), f, mode === 'print' || mode === 'print-eval' ? ['undefined', 'function'] : 'function\n');
  });
}

for (const withArgument of [false, true]) {
  test(`stdin imports without a server even when dash names the wrapper: argument=${withArgument}`, (t) => {
    const f = fixture(t);
    imported(f.run(['--input-type=module', '-', ...(withArgument ? [f.wrapper] : [])], f.importCode), f);
  });
}

for (const variant of ['missing', 'not-directory', 'loop']) {
  test(`file consumers handle ${variant} entry metadata without starting a server`, (t) => {
    const f = fixture(t);
    const loop = path.join(f.root, 'loop');
    if (variant === 'loop') symlinkSync(loop, loop);
    const entry = variant === 'missing' ? path.join(f.root, 'missing.js') : variant === 'not-directory' ? path.join(f.wrapper, 'child') : loop;
    const consumer = path.join(f.root, 'consumer.mjs');
    writeFileSync(consumer, `process.argv[1] = ${JSON.stringify(entry)}; ${f.importCode}`);
    const result = f.run([consumer]);
    if (variant === 'loop') {
      assert.equal(result.error, undefined);
      assert.equal(result.signal, null);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /ELOOP/);
      assert.equal(existsSync(f.marker), false);
    } else imported(result, f);
  });
}

for (const variant of ['direct', 'symlink', 'preserved-symlink', 'ordinary-eval-argument']) {
  test(`real ${variant} entrypoint starts the inert sibling exactly once`, (t) => {
    const f = fixture(t);
    const args = variant === 'preserved-symlink' ? ['--preserve-symlinks-main', f.alias]
      : [variant === 'symlink' ? f.alias : f.wrapper, ...(variant === 'ordinary-eval-argument' ? ['--eval'] : [])];
    const result = f.run(args);
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(f.marker, 'utf8'), 'started\n');
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /Server exited cleanly/);
  });
}
