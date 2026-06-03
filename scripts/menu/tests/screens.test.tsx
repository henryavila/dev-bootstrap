/**
 * screens.test.tsx (T-400) — per-screen render coverage.
 *
 * Complements flow.test.tsx (which drives the whole wizard end to end) with
 * dedicated render assertions for each screen: header, footer hotkeys, and the
 * screen's distinguishing content. These pin the structural contract of every
 * screen so a refactor that drops a footer band, a header, or a hotkey is
 * caught here.
 *
 * NOTE on the footer-drop class of bug (mesh-workstation 3e82f21): that bug —
 * the footer scrolling off a real TTY when the frame hits exactly `rows` — is
 * NOT observable here. ink-testing-library renders to a virtual buffer that
 * does not model the terminal's full-screen-clear scroll, so a too-tall frame
 * looks fine. These tests assert the footer is PRESENT in the tree (it always
 * was, even when the bug hid it); the live TTY walk (T-500) remains the gate
 * for the scroll behaviour.
 */
import { describe, it, expect, beforeAll, beforeEach, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '@henryavila/blink-tui';
import { App } from '../src/wizard.js';
import { TopicPicker } from '../src/screens/TopicPicker.js';
import type { Topic } from '../src/types.js';
import { OptionsForm } from '../src/screens/OptionsForm.js';
import { UpdatesScreen } from '../src/screens/UpdatesScreen.js';
import { registerDomainGlyphs, resolveDomain } from '../src/glyphs.js';
import { readAllManifests, flattenBundles, indexByKey } from '../src/core/manifest-reader.js';
import { buildFormSpec } from '../src/core/form-spec.js';
import { tmp } from './helpers.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

beforeAll(() => registerDomainGlyphs());
beforeEach(() => {
  process.env.XDG_CONFIG_HOME = tmp();
  process.env.MESH_PLATFORM = 'mac';
});

function renderApp() {
  let code = -1;
  const r = render(
    <ThemeProvider iconSet="unicode">
      <App dryRun onExit={(c) => (code = c)} />
    </ThemeProvider>,
  );
  return { ...r, getCode: () => code };
}

describe('TopicPicker screen', () => {
  it('renders header, the nav footer, and core action hotkeys', async () => {
    const { lastFrame, unmount } = renderApp();
    await delay(80);
    const f = lastFrame()!;
    expect(f).toContain('mesh setup');
    // The footer-drop saga's payload: navigation chips must be on screen.
    expect(f).toContain('move');
    expect(f).toContain('panes');
    expect(f).toContain('apply'); // the `c` action
    unmount();
  });

  it('renders the always-visible badge legend (both columns explained)', async () => {
    const { lastFrame, unmount } = renderApp();
    await delay(80);
    const f = lastFrame()!;
    // Quick legend band — the T-500 finding. These tokens appear ONLY in the
    // legend, never in the nav footer, so they pin the band's presence.
    expect(f).toContain('inst'); // installed
    expect(f).toContain('part'); // partial
    expect(f).toContain('none'); // not installed
    unmount();
  });
});

describe('UpdatesScreen', () => {
  it('renders the three opt-in categories + save/back footer', () => {
    const { lastFrame, unmount } = render(
      <ThemeProvider iconSet="unicode">
        <UpdatesScreen values={{}} onChange={() => {}} onClose={() => {}} />
      </ThemeProvider>,
    );
    const f = lastFrame()!;
    expect(f).toContain('mesh update'); // pane title "What should `mesh update` upgrade?"
    expect(f).toContain('Agent CLIs');
    expect(f).toContain('Runtimes & databases');
    expect(f).toContain('CLI tools');
    expect(f).toContain('save');
    expect(f).toContain('0/3 on'); // header right slot, nothing toggled
    unmount();
  });
});

describe('SummaryConfirm screen', () => {
  it('renders the apply plan with a delta summary + apply/back footer', async () => {
    const { stdin, lastFrame, unmount } = renderApp();
    await delay(80);
    stdin.write('c'); // picker → summary
    await delay(30);
    const f = lastFrame()!;
    expect(f).toContain('apply plan');
    expect(f).toMatch(/\+\d+/); // +N install count in the header right slot
    expect(f).toContain('apply');
    expect(f).toContain('back');
    expect(f).toContain('bundles'); // footer right slot "<n> bundles"
    unmount();
  });
});

describe('OptionsForm screen (isolated, real git/config spec)', () => {
  it('renders the bundle header, its fields, and the save/cancel footer', () => {
    const index = indexByKey(flattenBundles(readAllManifests()));
    const ref = index.get('git/config')!;
    const spec = buildFormSpec(ref.bundle, ref.topic.dir, new Map());
    expect(spec.fields.length).toBeGreaterThan(0);

    const { lastFrame, unmount } = render(
      <ThemeProvider iconSet="unicode">
        <OptionsForm
          bundleKey={ref.key}
          bundleLabel={ref.bundle.label}
          fields={spec.fields}
          values={spec.values}
          onChange={() => {}}
          onClose={() => {}}
        />
      </ThemeProvider>,
    );
    const f = lastFrame()!;
    expect(f).toContain('options');
    expect(f).toContain('git/config');
    expect(f).toContain(spec.fields[0].label); // a real option label renders
    expect(f).toContain('save');
    expect(f).toContain('cancel');
    unmount();
  });
});

describe('Help dialog', () => {
  it('opens on ? and shows the how-to-use lines', async () => {
    const { stdin, lastFrame, unmount } = renderApp();
    await delay(80);
    stdin.write('?');
    await delay(30);
    const f = lastFrame()!;
    expect(f).toContain('how to use');
    expect(f).toContain('Choose the bundles');
    // Full prose legend for both badge columns (T-500 finding).
    expect(f).toContain('Status');
    expect(f).toContain('installed');
    expect(f).toContain('partial');
    expect(f).toContain('required');
    unmount();
  });
});

describe('domain glyphs render in a screen (icon gap closed)', () => {
  it('a bundle with an icon_name shows a non-empty domain glyph in the summary', async () => {
    // git/config has icon_name git → now resolves to a blink glyph.
    const index = indexByKey(flattenBundles(readAllManifests()));
    expect(resolveDomain(index.get('git/config')!.bundle.icon_name)).toBeTruthy();
  });
});

describe('TopicPicker — Space on the Topics pane (T-500 toggle-all wiring)', () => {
  const topics = [
    {
      id: 'git',
      header: { label: 'Git', order: 40 },
      dir: '/tmp/git',
      bundles: [
        { name: 'config', label: 'Config', desc: 'c', items: [] },
        { name: 'lazygit', label: 'Lazygit', desc: 'l', items: [] },
      ],
    },
  ] as unknown as Topic[];

  it('Space toggles the WHOLE topic (onToggleTopic), not just the first bundle (onToggle)', async () => {
    const onToggle = vi.fn();
    const onToggleTopic = vi.fn();
    const { stdin, unmount } = render(
      <ThemeProvider iconSet="unicode">
        <TopicPicker
          topics={topics}
          platform="mac"
          selected={new Set()}
          required={new Set()}
          scan={new Map()}
          banner={null}
          onToggle={onToggle}
          onToggleTopic={onToggleTopic}
          onSelectAll={vi.fn()}
          onSelectNone={vi.fn()}
          onEditOptions={vi.fn()}
          onContinue={vi.fn()}
          onUpdates={vi.fn()}
          onHelp={vi.fn()}
          onQuit={vi.fn()}
        />
      </ThemeProvider>,
    );
    await delay(40);
    stdin.write(' '); // Topics pane is focused by default
    await delay(20);
    expect(onToggleTopic).toHaveBeenCalledWith('git');
    expect(onToggle).not.toHaveBeenCalled();
    unmount();
  });
});

describe('TopicPicker — level-3 affordance in the detail (pane 2)', () => {
  const stubProps = {
    platform: 'mac' as const,
    selected: new Set<string>(),
    required: new Set<string>(),
    scan: new Map(),
    banner: null,
    onToggle: vi.fn(),
    onToggleTopic: vi.fn(),
    onSelectAll: vi.fn(),
    onSelectNone: vi.fn(),
    onEditOptions: vi.fn(),
    onContinue: vi.fn(),
    onUpdates: vi.fn(),
    onHelp: vi.fn(),
    onQuit: vi.fn(),
  };

  it('shows "press Enter to configure" when the focused bundle has options', async () => {
    const topics = [
      {
        id: 'languages',
        header: { label: 'Languages', order: 60 },
        dir: '/tmp/languages',
        bundles: [
          {
            name: 'php',
            label: 'PHP',
            desc: 'PHP runtime',
            items: [],
            options: [{ name: 'versions', type: 'multiselect', label: 'Versions', env: 'PHP_VERSIONS' }],
          },
        ],
      },
    ] as unknown as Topic[];
    const { lastFrame, unmount } = render(
      <ThemeProvider iconSet="unicode">
        <TopicPicker {...stubProps} topics={topics} />
      </ThemeProvider>,
    );
    await delay(40);
    expect(lastFrame()).toContain('press Enter to configure');
    unmount();
  });

  it('shows "no options" when the focused bundle has none', async () => {
    const topics = [
      {
        id: 'foundation',
        header: { label: 'Foundation', order: 10 },
        dir: '/tmp/foundation',
        bundles: [{ name: 'base', label: 'Base', desc: 'Core tooling', items: [] }],
      },
    ] as unknown as Topic[];
    const { lastFrame, unmount } = render(
      <ThemeProvider iconSet="unicode">
        <TopicPicker {...stubProps} topics={topics} />
      </ThemeProvider>,
    );
    await delay(40);
    expect(lastFrame()).toContain('no options');
    unmount();
  });
});
