#!/usr/bin/env node
// scripts/menu/index.js — launcher + dependency self-provisioner.
//
// EVERY way the menu starts runs `node index.js` (setup.sh, scripts/runners/
// menu.sh, `npm start`, or a direct call). So this is the single place that can
// GUARANTEE the menu's dependencies are present and EXACTLY match the committed
// package-lock.json BEFORE anything imports them — a fresh OR stale machine
// self-heals here, with no user action and no "go run npm" error. (A new box
// must just work from `bash setup.sh`; asking the operator to install something
// only the setup uses is the bug this avoids.)
//
// The pre-flight uses ONLY node built-ins: tsx/react/ink/blink may not exist
// yet, so tsx-register.mjs (which loads tsx) and the app are imported
// DYNAMICALLY, *after* deps are ensured — a static `import` would be evaluated
// before the check runs. tsx-register pins THIS package's tsconfig so the
// TypeScript + JSX under src/ runs straight from source (no compile, no dist),
// regardless of the caller's CWD.
//
// Args are forwarded to src/app.tsx via process.argv (e.g. --dry-run).
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const BLINK = '@henryavila/blink-tui';
const BLINK_PKG_JSON = join(HERE, 'node_modules', '@henryavila', 'blink-tui', 'package.json');
const LOCKFILE = join(HERE, 'package-lock.json');

// Read a JSON file and pick a field; null on any error (absent / unreadable /
// malformed). Read the file directly rather than require()-ing it: blink is
// ESM-only and its "exports" map blocks the ./package.json subpath.
function pick(file, get) {
  try {
    return get(JSON.parse(readFileSync(file, 'utf8'))) ?? null;
  } catch {
    return null;
  }
}

const installedBlink = () => pick(BLINK_PKG_JSON, (j) => j.version);
const lockedBlink = () =>
  pick(LOCKFILE, (j) => j.packages?.['node_modules/@henryavila/blink-tui']?.version);

// Ensure node_modules is present and EXACTLY matches the lockfile; return true
// when the menu can run. `npm ci` is the only install that guarantees the
// pinned tree (it wipes node_modules and installs the lockfile verbatim), so a
// missing dir OR a version drift (e.g. an old 0.1.1 left after the lockfile
// moved to 0.2.0 — which silently breaks the dev-root `path` field) both
// converge here. A correct tree is left untouched: no reinstall per launch.
function ensureDeps() {
  const locked = lockedBlink();
  const have = installedBlink();
  if (have && (locked == null || have === locked)) return true; // already correct
  process.stderr.write('mesh menu: provisioning dependencies (npm ci)…\n');
  try {
    execSync('npm ci --omit=dev --no-audit --no-fund', { cwd: HERE, stdio: 'inherit' });
  } catch {
    // Offline / blocked registry / npm missing — re-checked below.
  }
  return installedBlink() != null;
}

if (!ensureDeps()) {
  process.stderr.write(
    `mesh menu: could not provision its dependencies (${BLINK}). ` +
      'Check network / npm registry access — the installer will fall back to ' +
      'the saved or default selection.\n',
  );
  process.exit(1); // setup.sh / menu.sh treat any non-0/130 as "fall back"
}

await import('./tsx-register.mjs');

await import('./src/app.tsx');
