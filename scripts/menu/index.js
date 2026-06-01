#!/usr/bin/env node
// scripts/menu/index.js — runtime launcher for the Ink + TypeScript setup wizard.
//
// The bash engine (setup.sh / scripts/runners/menu.sh) calls `node index.js`
// directly, with no build step. We register `tsx` (esbuild-backed, a prod
// dependency) so the TypeScript + JSX app under src/ runs straight from source
// on a fresh machine — no compile, no committed dist.
//
// Args are forwarded to src/app.tsx via process.argv (e.g. --dry-run).
import { register } from 'tsx/esm/api';

register();
await import('./src/app.tsx');
