/**
 * ai-pick.test.tsx — the SearchPicker (realtime-filter project/tab picker for
 * `mesh ai`) + its pure helpers. Covers the runner→TUI contract: parse the
 * merged candidate set (`label<TAB>path<TAB>wsid<TAB>status<TAB>tabid`), filter
 * by substring (including tab names), render open vs closed rows, Enter hands
 * back the chosen raw line, Tab opens an action menu, Ctrl-P opens local
 * preferences, Esc cancels.
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
  preferenceSummary,
} from '../src/screens/SearchPicker.js';
import { parseAiPickArgs } from '../src/ai-pick-main.js';
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

describe('preferenceSummary', () => {
  it('shows the current agent, open action and existing-workspace behavior', () => {
    expect(preferenceSummary('codex', 'shell', 'new')).toBe('agent=codex · open=shell · open existing=new');
  });
});

describe('parseAiPickArgs (runner → picker contract)', () => {
  it('parses --in + --out', () => {
    expect(parseAiPickArgs(['--in', '/tmp/c', '--out', '/tmp/o'])).toEqual({ in: '/tmp/c', out: '/tmp/o' });
  });
  it('null when either is missing', () => {
    expect(parseAiPickArgs(['--in', '/tmp/c'])).toBeNull();
    expect(parseAiPickArgs(['--out', '/tmp/o'])).toBeNull();
    expect(parseAiPickArgs([])).toBeNull();
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

  // The action arg distinguishes Enter (saved default) from explicit menu
  // choices such as shell, named agents, and local preference updates.
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

  it('Tab opens an actions menu and Enter chooses the focused action', async () => {
    const { stdin, calls } = mountWithAction();
    await delay(20);
    stdin.write('atomic'); // → the open atomic-skills workspace row (wsid w456)
    await delay(20);
    stdin.write('\t'); // actions
    await delay(20);
    stdin.write('\x1B[B'); // down: Open with Grok
    await delay(20);
    stdin.write('\x1B[B'); // down: Open with Claude
    await delay(20);
    stdin.write('\x1B[B'); // down: Open with Codex
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual([{ raw: 'atomic-skills\t/srv/atomic-skills\tw456\tdone\t', action: 'agent:codex' }]);
  });

  it('action menu can choose shell', async () => {
    const { stdin, calls } = mountWithAction();
    await delay(20);
    stdin.write('arch');
    await delay(20);
    stdin.write('\t');
    await delay(20);
    stdin.write('\x1B[B'); // Grok
    await delay(20);
    stdin.write('\x1B[B'); // Claude
    await delay(20);
    stdin.write('\x1B[B'); // Codex
    await delay(20);
    stdin.write('\x1B[B'); // Shell
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual([{ raw: 'arch\t/srv/ext/arch\t\t\t', action: 'shell' }]);
  });

  it('Ctrl-P opens preferences and returns a pref action', async () => {
    const { stdin, calls } = mountWithAction();
    await delay(20);
    stdin.write('\x10'); // Ctrl-P
    await delay(20);
    stdin.write('\x1B[B'); // Default agent: Claude (Grok is first)
    await delay(20);
    stdin.write('\x1B[B'); // Default agent: Codex
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual([{ raw: 'mesh-identity\t/srv/mesh-identity\tw123\tblocked\t', action: 'pref:agent:codex' }]);
  });

  it('Ctrl-P preferences display the current saved defaults', async () => {
    const oldAgent = process.env.MESH_AI_DEFAULT_AGENT;
    const oldAction = process.env.MESH_AI_DEFAULT_ACTION;
    const oldExisting = process.env.MESH_AI_OPEN_EXISTING;
    process.env.MESH_AI_DEFAULT_AGENT = 'codex';
    process.env.MESH_AI_DEFAULT_ACTION = 'shell';
    process.env.MESH_AI_OPEN_EXISTING = 'new';
    try {
      const { stdin, lastFrame } = mountWithAction();
      await delay(20);
      stdin.write('\x10'); // Ctrl-P
      await delay(20);
      const f = lastFrame() ?? '';
      expect(f).toContain('agent=codex');
      expect(f).toContain('open=shell');
      expect(f).toContain('open existing=new');
      expect(f).toContain('Default agent: Codex (current)');
      expect(f).toContain('Enter opens shell (current)');
      expect(f).toContain('Open existing: new tab (current)');
    } finally {
      if (oldAgent === undefined) delete process.env.MESH_AI_DEFAULT_AGENT;
      else process.env.MESH_AI_DEFAULT_AGENT = oldAgent;
      if (oldAction === undefined) delete process.env.MESH_AI_DEFAULT_ACTION;
      else process.env.MESH_AI_DEFAULT_ACTION = oldAction;
      if (oldExisting === undefined) delete process.env.MESH_AI_OPEN_EXISTING;
      else process.env.MESH_AI_OPEN_EXISTING = oldExisting;
    }
  });

  it('Esc backs out of a submenu before cancelling search', async () => {
    const { stdin, lastFrame, calls } = mountWithAction();
    await delay(20);
    stdin.write('\t');
    await delay(20);
    expect(lastFrame() ?? '').toContain('Open with Grok');
    stdin.write('\x1B');
    await delay(20);
    const f = lastFrame() ?? '';
    expect(f).toContain('mesh-identity');
    expect(f).not.toContain('Open with Codex');
    expect(calls).toEqual([]);
  });
});
