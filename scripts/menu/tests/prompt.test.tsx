/**
 * prompt.test.tsx — the single-field PromptScreen + its pure arg parser. Covers
 * the bash→TUI contract: text/secret accept-or-default, confirm y/n, Esc cancel.
 */
import { describe, it, expect, beforeAll } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '@henryavila/blink-tui';
import { PromptScreen, parsePromptArgs, parseChoices, isYes } from '../src/screens/PromptScreen.js';
import { PauseScreen } from '../src/screens/PauseScreen.js';
import { registerDomainGlyphs } from '../src/glyphs.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
beforeAll(() => registerDomainGlyphs());

function renderPrompt(props: {
  type: 'text' | 'secret' | 'confirm';
  label: string;
  defaultValue?: string;
}) {
  const calls: (string | null)[] = [];
  const r = render(
    <ThemeProvider iconSet="unicode">
      <PromptScreen {...props} onDone={(v) => calls.push(v)} />
    </ThemeProvider>,
  );
  return { ...r, calls };
}

describe('parsePromptArgs (bash → prompt contract)', () => {
  it('parses a valid text prompt', () => {
    expect(parsePromptArgs(['--type', 'text', '--label', 'Name', '--out', '/tmp/x'])).toEqual({
      type: 'text',
      label: 'Name',
      default: '',
      out: '/tmp/x',
      choices: [],
    });
  });
  it('accepts secret + confirm + pause + --default', () => {
    expect(parsePromptArgs(['--type', 'secret', '--out', '/tmp/x'])?.type).toBe('secret');
    expect(parsePromptArgs(['--type', 'confirm', '--out', '/o', '--default', 'y'])?.default).toBe('y');
    expect(parsePromptArgs(['--type', 'pause', '--out', '/o', '--label', 'wait'])?.type).toBe('pause');
  });
  it('rejects a bad/missing type or a missing --out', () => {
    expect(parsePromptArgs(['--type', 'bogus', '--out', '/x'])).toBeNull();
    expect(parsePromptArgs(['--type', 'text'])).toBeNull();
    expect(parsePromptArgs([])).toBeNull();
  });
  it('select needs choices', () => {
    expect(parsePromptArgs(['--type', 'select', '--out', '/o'])).toBeNull();
    const ok = parsePromptArgs(['--type', 'select', '--out', '/o', '--choices', 'a=A\nb=B']);
    expect(ok?.type).toBe('select');
    expect(ok?.choices).toEqual([
      { id: 'a', label: 'A' },
      { id: 'b', label: 'B' },
    ]);
  });
});

describe('parseChoices', () => {
  it('splits id=label per line, on the FIRST =, dropping blanks', () => {
    expect(parseChoices('mesh=A few\nstar=Many (k=v ok)')).toEqual([
      { id: 'mesh', label: 'A few' },
      { id: 'star', label: 'Many (k=v ok)' },
    ]);
    expect(parseChoices('')).toEqual([]);
    expect(parseChoices(undefined)).toEqual([]);
    expect(parseChoices('bare')).toEqual([{ id: 'bare', label: 'bare' }]);
  });
});

describe('isYes', () => {
  it('maps y/yes/true/1 → yes, everything else → no', () => {
    for (const s of ['y', 'Y', 'yes', 'true', '1']) expect(isYes(s)).toBe(true);
    for (const s of ['n', 'no', '', 'x', '0']) expect(isYes(s)).toBe(false);
  });
});

describe('PromptScreen — text', () => {
  it('types then Enter returns the typed value', async () => {
    const { stdin, calls, unmount } = renderPrompt({ type: 'text', label: 'Name' });
    await delay(20);
    stdin.write('abc');
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual(['abc']);
    unmount();
  });
  it('empty Enter returns the default', async () => {
    const { stdin, calls, unmount } = renderPrompt({ type: 'text', label: 'Dir', defaultValue: '/opt' });
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual(['/opt']);
    unmount();
  });
  it('Esc cancels (null)', async () => {
    const { stdin, calls, unmount } = renderPrompt({ type: 'text', label: 'Name' });
    await delay(20);
    stdin.write('');
    await delay(20);
    expect(calls).toEqual([null]);
    unmount();
  });
});

describe('PromptScreen — select', () => {
  const CHOICES = [
    { id: 'mesh', label: 'A few' },
    { id: 'star', label: 'Many' },
  ];
  function renderSelect(defaultValue: string) {
    const calls: (string | null)[] = [];
    const r = render(
      <ThemeProvider iconSet="unicode">
        <PromptScreen
          type="select"
          label="Topology"
          defaultValue={defaultValue}
          choices={CHOICES}
          onDone={(v) => calls.push(v)}
        />
      </ThemeProvider>,
    );
    return { ...r, calls };
  }
  it('Enter accepts the pre-selected default', async () => {
    const { stdin, calls, unmount } = renderSelect('star');
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual(['star']);
    unmount();
  });
  it('Space selects the focused choice, Enter accepts it', async () => {
    const { stdin, calls, unmount } = renderSelect('star');
    await delay(20);
    stdin.write(' '); // select the focused (first) choice → mesh
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual(['mesh']);
    unmount();
  });
  it('Esc cancels (null)', async () => {
    const { stdin, calls, unmount } = renderSelect('star');
    await delay(20);
    stdin.write('\x1B');
    await delay(20);
    expect(calls).toEqual([null]);
    unmount();
  });
});

describe('PauseScreen — acknowledge (Dialog, not a field)', () => {
  function renderPause() {
    const calls: boolean[] = [];
    const r = render(
      <ThemeProvider iconSet="unicode">
        <PauseScreen label="approve on the hub" onDone={(ok) => calls.push(ok)} />
      </ThemeProvider>,
    );
    return { ...r, calls };
  }
  it('Enter continues (true), Esc skips (false)', async () => {
    let r = renderPause();
    await delay(20);
    r.stdin.write('\r');
    await delay(20);
    expect(r.calls).toEqual([true]);
    r.unmount();

    r = renderPause();
    await delay(20);
    r.stdin.write('\x1B'); // Esc
    await delay(20);
    expect(r.calls).toEqual([false]);
    r.unmount();
  });
  it('shows the message (not a text box)', async () => {
    const r = renderPause();
    await delay(20);
    expect(r.lastFrame()).toContain('approve on the hub');
    r.unmount();
  });
});

describe('PromptScreen — confirm', () => {
  it('y → yes, n → no, Esc → cancel', async () => {
    let r = renderPrompt({ type: 'confirm', label: 'OK?' });
    await delay(20);
    r.stdin.write('y');
    await delay(20);
    expect(r.calls).toEqual(['y']);
    r.unmount();

    r = renderPrompt({ type: 'confirm', label: 'OK?' });
    await delay(20);
    r.stdin.write('n');
    await delay(20);
    expect(r.calls).toEqual(['n']);
    r.unmount();

    r = renderPrompt({ type: 'confirm', label: 'OK?' });
    await delay(20);
    r.stdin.write('');
    await delay(20);
    expect(r.calls).toEqual([null]);
    r.unmount();
  });
});
