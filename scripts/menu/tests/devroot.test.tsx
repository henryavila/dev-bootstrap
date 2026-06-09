import { describe, it, expect, beforeAll } from 'vitest';
import { render } from 'ink-testing-library';
import { homedir } from 'node:os';
import { ThemeProvider } from '@henryavila/blink-tui';
import {
  DevRootScreen,
  resolveDevRoot,
  devRootStatus,
  CODE_DIR_ENV,
} from '../src/screens/DevRootScreen.js';
import { registerDomainGlyphs } from '../src/glyphs.js';
import { tmp } from './helpers.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
beforeAll(() => registerDomainGlyphs());

function renderScreen(initial: string, onClose: (r: string | null) => void) {
  return render(
    <ThemeProvider iconSet="unicode">
      <DevRootScreen initial={initial} onClose={onClose} />
    </ThemeProvider>,
  );
}

describe('resolveDevRoot (app-side path expansion — blink stays no-I/O)', () => {
  const home = '/home/test';
  it('empty → home/code (the default dev root); explicit ~ → home', () => {
    expect(resolveDevRoot('', home)).toBe('/home/test/code');
    expect(resolveDevRoot('  ', home)).toBe('/home/test/code');
    expect(resolveDevRoot('~', home)).toBe(home);
  });
  it('~/x and $HOME/x expand under home', () => {
    expect(resolveDevRoot('~/code', home)).toBe('/home/test/code');
    expect(resolveDevRoot('$HOME', home)).toBe(home);
    expect(resolveDevRoot('$HOME/code', home)).toBe('/home/test/code');
  });
  it('absolute paths pass through; bare names land under home', () => {
    expect(resolveDevRoot('/srv/code', home)).toBe('/srv/code');
    expect(resolveDevRoot('code', home)).toBe('/home/test/code');
  });
  it('defaults home to the real os.homedir() when omitted', () => {
    expect(resolveDevRoot('')).toBe(homedir() + '/code');
  });
});

describe('devRootStatus (app computes; fed to blink as an intent)', () => {
  it('an existing directory → exists', () => {
    expect(devRootStatus(tmp())).toBe('exists');
  });
  it('a missing path → create (never throws)', () => {
    expect(devRootStatus('/no/such/dev/root/here')).toBe('create');
  });
});

describe('DevRootScreen', () => {
  it('CODE_DIR_ENV is the dev-root contract key', () => {
    expect(CODE_DIR_ENV).toBe('CODE_DIR');
  });

  it('Enter saves the RESOLVED absolute path (never a literal ~)', async () => {
    let result: string | null | undefined;
    const { stdin } = renderScreen('', (r) => (result = r));
    await delay(20);
    stdin.write('~/code');
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(result).toBe(resolveDevRoot('~/code'));
    expect(result).not.toContain('~');
  });

  it('Enter on the empty field saves home/code (the default dev root)', async () => {
    let result: string | null | undefined;
    const { stdin } = renderScreen('', (r) => (result = r));
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(result).toBe(homedir() + '/code');
  });

  it('Esc skips without writing (onClose null → keep current/default)', async () => {
    let result: string | null | undefined = undefined;
    const { stdin } = renderScreen('/seed/path', (r) => (result = r));
    await delay(20);
    stdin.write('\u001B'); // Esc
    await delay(20);
    expect(result).toBeNull();
  });

  it('renders the resolved preview line for the seeded value', async () => {
    const { lastFrame } = renderScreen('/srv/code', () => {});
    await delay(20);
    expect(lastFrame()).toContain('dev root');
    expect(lastFrame()).toContain('/srv/code'); // app-fed preview line
  });
});
