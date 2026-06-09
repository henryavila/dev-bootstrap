/**
 * launcher.test.ts — regression guard for the production launch path.
 *
 * The in-process screen/flow tests render under vitest's own esbuild, which
 * always uses the automatic JSX runtime, so they NEVER exercised how setup.sh
 * actually starts the menu: `node scripts/menu/index.js` with CWD = workstation
 * root. From there tsx found no tsconfig, fell back to the classic
 * React.createElement transform, and the app crashed with "React is not
 * defined" at first render (the crash is *after* app.tsx's TTY guard, so a
 * headless `node index.js` exits at the guard and never reveals it — which is
 * why this slipped through). Fixed by tsx-register.mjs pinning the tsconfig.
 *
 * This test reproduces the exact condition: spawn node from the repo root,
 * load the REAL tsx-register.mjs, then import a top-level-JSX fixture (so the
 * transform runs at import, no TTY). Classic transform → throws; automatic →
 * prints the marker.
 */
import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const menuDir = resolve(dirname(fileURLToPath(import.meta.url)), '..'); // scripts/menu
const repoRoot = resolve(menuDir, '..', '..'); // workstation root

describe('launcher tsx bootstrap', () => {
  it('uses the automatic JSX runtime when launched from the repo root (like setup.sh)', () => {
    const register = join(menuDir, 'tsx-register.mjs');
    const fixture = join(menuDir, 'tests', 'fixtures', 'jsx-smoke.tsx');
    const code =
      `await import(${JSON.stringify(register)});` +
      `await import(${JSON.stringify(fixture)});`;
    const out = execFileSync('node', ['--input-type=module', '--eval', code], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    expect(out).toContain('JSX_SMOKE_OK');
  });
});
