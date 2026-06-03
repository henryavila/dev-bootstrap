import { describe, it, expect, beforeAll } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '@henryavila/blink-tui';
import {
  IdentityOnboarding,
  adoptDelta,
  createDelta,
  IDENTITY_ENV,
  type IdentityResult,
} from '../src/screens/IdentityOnboarding.js';
import { isIdentityOnboarding } from '../src/wizard.js';
import { readAllManifests, flattenBundles, indexByKey } from '../src/core/manifest-reader.js';
import { registerDomainGlyphs } from '../src/glyphs.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
beforeAll(() => registerDomainGlyphs());

function renderScreen(
  initial: Map<string, string>,
  onClose: (r: IdentityResult | null) => void,
  opts: { notice?: string; defaultOwner?: string } = {},
) {
  return render(
    <ThemeProvider iconSet="unicode">
      <IdentityOnboarding initial={initial} onClose={onClose} notice={opts.notice} defaultOwner={opts.defaultOwner} />
    </ThemeProvider>,
  );
}

describe('identity delta builders', () => {
  it('adoptDelta trims the repo and clears every create-* key', () => {
    const d = adoptDelta('  git@github.com:me/x.git ');
    expect(d[IDENTITY_ENV.repo]).toBe('git@github.com:me/x.git');
    expect(d[IDENTITY_ENV.create]).toBeNull();
    expect(d[IDENTITY_ENV.template]).toBeNull();
    expect(d[IDENTITY_ENV.owner]).toBeNull();
    expect(d[IDENTITY_ENV.name]).toBeNull();
    expect(d[IDENTITY_ENV.private]).toBeNull();
  });

  it('createDelta sets the full create env set + an owner/name placeholder repo', () => {
    const d = createDelta({ template: 'o/t', owner: ' me ', name: ' mesh-identity ', private: true });
    expect(d[IDENTITY_ENV.create]).toBe('1');
    expect(d[IDENTITY_ENV.template]).toBe('o/t');
    expect(d[IDENTITY_ENV.owner]).toBe('me');
    expect(d[IDENTITY_ENV.name]).toBe('mesh-identity');
    expect(d[IDENTITY_ENV.private]).toBe('1');
    expect(d[IDENTITY_ENV.repo]).toBe('me/mesh-identity');
  });

  it('createDelta private:false → 0', () => {
    expect(createDelta({ template: 'o/t', owner: 'me', name: 'x', private: false })[IDENTITY_ENV.private]).toBe('0');
  });
});

describe('isIdentityOnboarding (wizard routing predicate)', () => {
  const index = indexByKey(flattenBundles(readAllManifests()));
  it('true for the personal bundle (it carries MESH_IDENTITY_REPO)', () => {
    expect(isIdentityOnboarding(index.get('personal/personal')!.bundle)).toBe(true);
  });
  it('false for a normal options bundle', () => {
    expect(isIdentityOnboarding(index.get('git/config')!.bundle)).toBe(false);
  });
});

describe('IdentityOnboarding screen', () => {
  it('mode → adopt → type a URL → Enter closes with the adopt delta', async () => {
    let result: IdentityResult | null | undefined;
    const { stdin, lastFrame } = renderScreen(new Map(), (r) => (result = r));
    await delay(20);
    expect(lastFrame()).toContain('Do you already have');
    stdin.write('\r'); // pick "adopt" (first row)
    await delay(20);
    stdin.write('git@github.com:me/x.git');
    await delay(20);
    stdin.write('\r'); // save
    await delay(20);
    expect(result).toBeTruthy();
    expect(result!.params[IDENTITY_ENV.repo]).toBe('git@github.com:me/x.git');
    expect(result!.params[IDENTITY_ENV.create]).toBeNull();
  });

  it('adopt with an empty repo does not close (required field blocks save)', async () => {
    let called = false;
    const { stdin } = renderScreen(new Map(), () => (called = true));
    await delay(20);
    stdin.write('\r'); // adopt
    await delay(20);
    stdin.write('\r'); // try to save with the field empty
    await delay(20);
    expect(called).toBe(false);
  });

  it('mode → create → Enter closes with the create delta (seeded defaults)', async () => {
    let result: IdentityResult | null | undefined;
    const { stdin } = renderScreen(new Map(), (r) => (result = r), { defaultOwner: 'me' });
    await delay(20);
    stdin.write('\u001B[B'); // ↓ to the "create" row
    await delay(20);
    stdin.write('\r'); // pick "create"
    await delay(20);
    stdin.write('\r'); // save with the seeded template/owner/name
    await delay(20);
    expect(result).toBeTruthy();
    expect(result!.params[IDENTITY_ENV.create]).toBe('1');
    expect(result!.params[IDENTITY_ENV.owner]).toBe('me');
    expect(result!.params[IDENTITY_ENV.name]).toBe('mesh-identity');
    expect(result!.params[IDENTITY_ENV.repo]).toBe('me/mesh-identity');
  });

  it('seeds the create step when params already carry CREATE_IDENTITY_FROM_TEMPLATE', async () => {
    const init = new Map([
      [IDENTITY_ENV.create, '1'],
      [IDENTITY_ENV.owner, 'me'],
      [IDENTITY_ENV.name, 'id'],
      [IDENTITY_ENV.template, 'o/t'],
    ]);
    const { lastFrame } = renderScreen(init, () => {});
    await delay(20);
    expect(lastFrame()).toContain('create from a template');
  });

  it('Esc on the mode pick cancels (onClose null)', async () => {
    let result: IdentityResult | null | undefined = undefined;
    const { stdin } = renderScreen(new Map(), (r) => (result = r));
    await delay(20);
    stdin.write('\u001B'); // Esc
    await delay(20);
    expect(result).toBeNull();
  });
});
