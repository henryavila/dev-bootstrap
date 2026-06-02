#!/usr/bin/env node
// scripts/menu/index.js — runtime launcher for the Ink + TypeScript setup wizard.
//
// The bash engine (setup.sh / scripts/runners/menu.sh) calls `node index.js`
// directly, with no build step. tsx-register.mjs registers `tsx` (esbuild-backed,
// a prod dependency) pinned to THIS package's tsconfig so the TypeScript + JSX
// app under src/ runs straight from source on a fresh machine — no compile, no
// committed dist — regardless of the caller's CWD. (See tsx-register.mjs for the
// React-not-defined bug this avoids.)
//
// Args are forwarded to src/app.tsx via process.argv (e.g. --dry-run).
import './tsx-register.mjs';

await import('./src/app.tsx');
