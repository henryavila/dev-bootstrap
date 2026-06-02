// tsx-register.mjs — shared tsx bootstrap for the setup wizard launcher.
//
// tsx resolves tsconfig.json relative to the process CWD. setup.sh (and
// scripts/runners/menu.sh) launch us as `node scripts/menu/index.js` from the
// WORKSTATION ROOT, where there is no tsconfig — so esbuild fell back to the
// CLASSIC JSX transform (React.createElement) and the app died with
// "React is not defined" the instant it rendered (app.tsx:34). The crash sits
// *after* app.tsx's TTY guard, so a headless `node index.js` never reaches it —
// which is why every in-process test missed it. Pin tsx to THIS package's
// tsconfig (jsx: react-jsx → automatic runtime) regardless of CWD.
//
// Regression-tested in tests/launcher.test.ts.
import { register } from 'tsx/esm/api';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
register({ tsconfig: join(here, 'tsconfig.json') });
