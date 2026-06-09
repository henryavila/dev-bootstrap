// jsx-smoke.tsx — fixture for tests/launcher.test.ts (NOT a test file itself).
//
// Top-level JSX so the tsx transform choice (automatic react-jsx vs classic
// React.createElement) is exercised at IMPORT time, with no TTY needed. If the
// launcher fails to pin tsx to the package tsconfig, importing this throws
// "React is not defined" — exactly the production crash, caught deterministically.
export const el = <></>;
console.log('JSX_SMOKE_OK');
