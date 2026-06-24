/**
 * ia-pick.test.tsx — the SearchPicker (realtime-filter project/tab picker for
 * `mesh ia`) + its pure helpers. Covers the runner→TUI contract: parse the
 * merged candidate set (`label<TAB>path<TAB>wsid<TAB>status<TAB>tabid`), filter
 * by substring (including tab names), render open vs closed rows, Enter hands
 * back the chosen raw line, Esc cancels.
 */
import { describe, it, expect, beforeAll } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '@henryavila/blink-tui';
import {
  SearchPicker,
  parseCandidates,
  filterItems,
  abbrevHome,
  rowMeta,
} from '../src/screens/SearchPicker.js';
import { parseIaPickArgs } from '../src/ia-pick-main.js';
import { registerDomainGlyphs } from '../src/glyphs.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
beforeAll(() => registerDomainGlyphs());

// Paths under /srv (not under any $HOME) so abbrevHome is a no-op → deterministic
// rendering regardless of the test runner's HOME. Row 2 is a TAB of row 1.
const CAND = [
  'mesh-identity\t/srv/mesh-identity\tw123\tblocked\t',
  'mesh-identity › Dashboard\t/srv/mesh-identity\tw123\tworking\tw123:2',
  'atomic-skills\t/srv/atomic-skills\tw456\tdone\t',
  'arch\t/srv/ext/arch\t\t\t',
  'sda\t/srv/sda\t\t\t',
].join('\n');

describe('parseCandidates', () => {
  const items = parseCandidates(CAND);
  it('parses label/path/wsid/status/tabid + the open flag', () => {
    expect(items).toHaveLength(5);
    expect(items[0]).toMatchObject({
      label: 'mesh-identity',
      path: '/srv/mesh-identity',
      wsid: 'w123',
      status: 'blocked',
      tabid: '',
      open: true,
      id: 'w123',
    });
    expect(items[3]).toMatchObject({ label: 'arch', wsid: '', tabid: '', open: false, id: '/srv/ext/arch' });
  });
  it('a tab row carries its tab_id and ids by it', () => {
    expect(items[1]).toMatchObject({
      label: 'mesh-identity › Dashboard',
      wsid: 'w123',
      tabid: 'w123:2',
      open: true,
      id: 'w123:2',
    });
  });
  it('keeps the raw line verbatim for hand-back', () => {
    expect(items[1].raw).toBe('mesh-identity › Dashboard\t/srv/mesh-identity\tw123\tworking\tw123:2');
  });
  it('drops blank and label-less lines', () => {
    expect(parseCandidates('\n\n\t/x\t\t\t\nok\t/y\t\t\t')).toHaveLength(1);
  });
});

describe('filterItems (substring, case-insensitive)', () => {
  const items = parseCandidates(CAND);
  it('empty query returns everything', () => {
    expect(filterItems(items, '')).toHaveLength(5);
  });
  it('matches a tab name', () => {
    expect(filterItems(items, 'dashboard').map((i) => i.label)).toEqual(['mesh-identity › Dashboard']);
  });
  it('matches any position, case-insensitive', () => {
    expect(filterItems(items, 'arch').map((i) => i.label)).toEqual(['arch']);
    expect(filterItems(items, 'sda')).toHaveLength(1);
  });
  it('no match returns empty', () => {
    expect(filterItems(items, 'zzz')).toHaveLength(0);
  });
});

describe('abbrevHome', () => {
  it('abbreviates an exact home and a child path', () => {
    expect(abbrevHome('/home/henry', '/home/henry')).toBe('~');
    expect(abbrevHome('/home/henry/arch', '/home/henry')).toBe('~/arch');
  });
  it('leaves non-home paths and empty home alone', () => {
    expect(abbrevHome('/srv/x', '/home/henry')).toBe('/srv/x');
    expect(abbrevHome('/home/henryNOT', '/home/henry')).toBe('/home/henryNOT');
    expect(abbrevHome('/srv/x', '')).toBe('/srv/x');
  });
});

describe('rowMeta', () => {
  const items = parseCandidates(CAND);
  it('open rows read `herdr <status> · <dir>`', () => {
    expect(rowMeta(items[0])).toBe('herdr blocked · /srv/mesh-identity');
    expect(rowMeta(items[1])).toBe('herdr working · /srv/mesh-identity'); // tab row
  });
  it('closed rows read just the dir', () => {
    expect(rowMeta(items[3])).toBe('/srv/ext/arch');
  });
});

describe('parseIaPickArgs (runner → picker contract)', () => {
  it('parses --in + --out', () => {
    expect(parseIaPickArgs(['--in', '/tmp/c', '--out', '/tmp/o'])).toEqual({ in: '/tmp/c', out: '/tmp/o' });
  });
  it('null when either is missing', () => {
    expect(parseIaPickArgs(['--in', '/tmp/c'])).toBeNull();
    expect(parseIaPickArgs(['--out', '/tmp/o'])).toBeNull();
    expect(parseIaPickArgs([])).toBeNull();
  });
});

describe('SearchPicker (render + keys)', () => {
  function mount() {
    const calls: (string | null)[] = [];
    const r = render(
      <ThemeProvider iconSet="unicode">
        <SearchPicker items={parseCandidates(CAND)} onDone={(v) => calls.push(v)} />
      </ThemeProvider>,
    );
    return { ...r, calls };
  }

  it('lists workspaces, tabs and closed repos', () => {
    const f = mount().lastFrame() ?? '';
    expect(f).toContain('mesh-identity');
    expect(f).toContain('Dashboard'); // the tab row
    expect(f).toContain('/srv/sda');
    expect(f).toContain('/srv/ext/arch');
  });

  it('filters live as you type', async () => {
    const { stdin, lastFrame } = mount();
    await delay(20);
    stdin.write('sda');
    await delay(20);
    const f = lastFrame() ?? '';
    expect(f).toContain('/srv/sda');
    expect(f).not.toContain('/srv/ext/arch');
    expect(f).not.toContain('Dashboard');
  });

  it('Enter on a filtered tab hands back the tab row raw', async () => {
    const { stdin, calls } = mount();
    await delay(20);
    stdin.write('Dashboard');
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual(['mesh-identity › Dashboard\t/srv/mesh-identity\tw123\tworking\tw123:2']);
  });

  it('Esc cancels with null', async () => {
    const { stdin, calls } = mount();
    await delay(20);
    stdin.write('\x1B');
    await delay(20);
    expect(calls).toEqual([null]);
  });

  // The action arg distinguishes Enter (focus/open the primary) from Ctrl-N
  // (open a NEW agent in the focused repo, even when its workspace is open).
  function mountWithAction() {
    const calls: Array<{ raw: string | null; action?: string }> = [];
    const r = render(
      <ThemeProvider iconSet="unicode">
        <SearchPicker items={parseCandidates(CAND)} onDone={(raw, action) => calls.push({ raw, action })} />
      </ThemeProvider>,
    );
    return { ...r, calls };
  }

  it('Enter carries the "open" action', async () => {
    const { stdin, calls } = mountWithAction();
    await delay(20);
    stdin.write('Dashboard');
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual([
      { raw: 'mesh-identity › Dashboard\t/srv/mesh-identity\tw123\tworking\tw123:2', action: 'open' },
    ]);
  });

  it('Ctrl-N hands back the focused row with the "new" action', async () => {
    const { stdin, calls } = mountWithAction();
    await delay(20);
    stdin.write('atomic'); // → the open atomic-skills workspace row (wsid w456)
    await delay(20);
    stdin.write('\x0e'); // Ctrl-N
    await delay(20);
    expect(calls).toEqual([{ raw: 'atomic-skills\t/srv/atomic-skills\tw456\tdone\t', action: 'new' }]);
  });
});
