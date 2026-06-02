/**
 * TopicPicker (T-304) — the 3-pane hierarchical bundle selector.
 *
 *   ┌ Topics ┐┌ <focused topic> ────────────┐
 *   │ tree   ││ bundles list (selectable)    │
 *   │        │└──────────────────────────────┘
 *   │        │┌ Detail ──────────────────────┐
 *   └────────┘│ focused bundle's attributes  │
 *             └──────────────────────────────┘
 *
 * BLINK-ONLY: every visible element is a blink component (Header, Pane, List,
 * DescriptionList, Banner, Footer); Ink <Box> is layout scaffolding only. Focus
 * is driven by blink's headless useListNavigation; selection + the closure live
 * in the parent (App) and arrive via props/callbacks.
 */
import { useMemo, useState } from 'react';
import { Box } from 'ink';
import { useInput } from 'ink';
import {
  Header,
  Pane,
  List,
  DescriptionList,
  Footer,
  Banner,
  useListNavigation,
  useStdoutDimensions,
  type ListRowData,
  type DescriptionItem,
  type HotkeyDef,
} from '@henryavila/blink-tui';
import { resolveDomain } from '../glyphs.js';
import type { BundleRef, Platform, Topic } from '../types.js';
import type { BundleScan } from '../core/scanner.js';

export interface TopicPickerProps {
  topics: Topic[];
  platform: Platform;
  /** Selected `topic/bundle` keys (closed under requires_bundles). */
  selected: Set<string>;
  /** Required keys — shown locked, never deselectable. */
  required: Set<string>;
  /** Per-bundle install state for the badges. */
  scan: Map<string, BundleScan>;
  /** A transient notice line under the panes (auto-select / cascade messages). */
  banner: string | null;
  onToggle: (key: string) => void;
  onSelectAll: () => void;
  onSelectNone: () => void;
  onEditOptions: (ref: BundleRef) => void;
  onContinue: () => void;
  onUpdates: () => void;
  onHelp: () => void;
  onQuit: () => void;
}

type Pane2 = 'topics' | 'bundles';

// Footer shows how to NAVIGATE + the core actions, so the main screen is
// self-explanatory. Power shortcuts (a/n select-all-none, u updates) stay in
// the `?` help to keep the bar from overloading. blink drops chips from the
// right when the width is tight, so navigation (leftmost) always survives.
const FOOTER_KEYS: HotkeyDef[] = [
  { k: '↑↓', desc: 'move' },
  { k: 'tab', desc: 'panes' },
  { k: 'space', desc: 'select' },
  { k: 'enter', desc: 'options' },
  { k: 'c', desc: 'apply' },
  { k: '?', desc: 'more' },
  { k: 'q', desc: 'quit' },
];

/** Map a bundle scan state to a blink List row `state` intent. */
function bundleStateIntent(scan: BundleScan | undefined): string | undefined {
  if (!scan) return undefined;
  if (scan.state === 'installed') return 'installed';
  if (scan.state === 'partial') return 'partial';
  return 'missing';
}

export function TopicPicker(props: TopicPickerProps) {
  const { topics, selected, required, scan, banner } = props;
  const [activePane, setActivePane] = useState<Pane2>('topics');
  const { rows: rawRows } = useStdoutDimensions();
  // Guard against a transient bad/0 reading (some stdouts report garbage on a
  // resize event) collapsing the layout; assume a sane terminal otherwise.
  const rows = rawRows >= 10 ? rawRows : 24;

  const topicNav = useListNavigation({ ids: topics.map((t) => t.id) });
  const focusedTopic = topics.find((t) => t.id === topicNav.focusedId) ?? topics[0];

  const bundleIds = focusedTopic.bundles.map((b) => b.name);
  const bundleNav = useListNavigation({ ids: bundleIds });
  const focusedBundle =
    focusedTopic.bundles.find((b) => b.name === bundleNav.focusedId) ?? focusedTopic.bundles[0];
  const focusedKey = `${focusedTopic.id}/${focusedBundle.name}`;

  // ── topic rows: label + "selected / total" meta ──
  const topicRows: ListRowData[] = useMemo(
    () =>
      topics.map((t) => {
        const total = t.bundles.length;
        const sel = t.bundles.filter((b) => selected.has(`${t.id}/${b.name}`)).length;
        return {
          id: t.id,
          label: t.header.label,
          meta: `${sel}/${total}`,
          muted: sel === 0,
        };
      }),
    [topics, selected],
  );

  // ── bundle rows for the focused topic ──
  const bundleRows: ListRowData[] = focusedTopic.bundles.map((b) => {
    const key = `${focusedTopic.id}/${b.name}`;
    const isRequired = required.has(key);
    const hasOptions = (b.options?.length ?? 0) > 0;
    return {
      id: b.name,
      label: b.label,
      state: bundleStateIntent(scan.get(key)),
      selected: selected.has(key),
      locked: isRequired,
      domain: resolveDomain(b.icon_name),
      meta: hasOptions ? 'opts' : undefined,
    };
  });
  const selectedBundleIds = new Set(
    focusedTopic.bundles.filter((b) => selected.has(`${focusedTopic.id}/${b.name}`)).map((b) => b.name),
  );

  // ── detail pane for the focused bundle ──
  const detail: DescriptionItem[] = useMemo(() => {
    const b = focusedBundle;
    const sc = scan.get(focusedKey);
    const items: DescriptionItem[] = [{ value: b.desc, muted: true }];
    if (sc) {
      items.push({ term: 'state', value: `${sc.state} (${sc.installed}/${sc.total})`, state: bundleStateIntent(sc) });
    }
    items.push({ term: 'items', value: String(b.items.length) });
    if (b.options?.length) {
      items.push({ term: 'options', value: b.options.map((o) => o.label).join(', ') });
    }
    if (b.requires_bundles?.length) {
      items.push({ term: 'requires', value: b.requires_bundles.join(', ') });
    }
    if (required.has(focusedKey)) {
      items.push({ term: 'required', value: 'always installed (locked)', muted: true });
    }
    return items;
  }, [focusedBundle, focusedKey, scan, required]);

  useInput((input, key) => {
    if (key.tab) {
      setActivePane((p) => (p === 'topics' ? 'bundles' : 'topics'));
      return;
    }
    if (key.upArrow || input === 'k') {
      (activePane === 'topics' ? topicNav : bundleNav).focusPrev();
      return;
    }
    if (key.downArrow || input === 'j') {
      (activePane === 'topics' ? topicNav : bundleNav).focusNext();
      return;
    }
    if (key.rightArrow && activePane === 'topics') {
      setActivePane('bundles');
      return;
    }
    if (key.leftArrow && activePane === 'bundles') {
      setActivePane('topics');
      return;
    }
    if (input === ' ') {
      if (!required.has(focusedKey)) props.onToggle(focusedKey);
      return;
    }
    if (key.return) {
      if ((focusedBundle.options?.length ?? 0) > 0) {
        props.onEditOptions({ topic: focusedTopic, bundle: focusedBundle, key: focusedKey });
      }
      return;
    }
    if (input === 'c') return props.onContinue();
    if (input === 'a') return props.onSelectAll();
    if (input === 'n') return props.onSelectNone();
    if (input === 'u') return props.onUpdates();
    if (input === '?') return props.onHelp();
    if (input === 'q') return props.onQuit();
  });

  const selectedCount = selected.size;
  // Pin the whole screen one row UNDER the terminal (blink's documented tip).
  // A frame exactly as tall as the terminal forces Ink onto a full-screen-clear
  // redraw that scrolls the bottom row — the footer — out of view on a real TTY
  // (pyte/ink-testing-library don't model the scroll, so it looks fine there).
  // The header, a *permanently reserved* banner row, and the footer are fixed
  // 1-row bands; the panes flex to fill the slack. Reserving the banner row even
  // when empty keeps the total height CONSTANT — so toggling a notice (e.g. the
  // auto-select banner on Space) never reflows the frame across that boundary,
  // which is the exact trigger that used to drop the footer. flexbox owns the
  // geometry: no per-line arithmetic decides whether the footer survives.
  const screenH = Math.max(8, rows - 1);
  const innerHeight = Math.max(6, screenH - 3); // header (1) + banner (1) + footer (1)
  const detailMax = Math.max(2, Math.floor(innerHeight * 0.4) - 2);
  const bundlesListH = Math.max(3, Math.floor((innerHeight - 4) * 0.6));

  return (
    <Box flexDirection="column" height={screenH}>
      <Box flexShrink={0} flexDirection="column">
        <Header
          title="mesh setup"
          subtitle={`${props.platform} · ${topics.length} topics`}
          right={`${selectedCount} bundles selected`}
        />
      </Box>
      <Box flexDirection="row" flexGrow={1} minHeight={0} overflow="hidden">
        <Pane title="Topics" tone={activePane === 'topics' ? 'focus' : 'resting'} flexBasis="32%">
          <List rows={topicRows} focusedId={activePane === 'topics' ? topicNav.focusedId : null} height={innerHeight - 2} />
        </Pane>
        <Box flexDirection="column" flexGrow={1}>
          <Pane title={focusedTopic.header.label} tone={activePane === 'bundles' ? 'focus' : 'resting'} flexGrow={1}>
            <List
              rows={bundleRows}
              focusedId={activePane === 'bundles' ? bundleNav.focusedId : null}
              selectedIds={selectedBundleIds}
              height={bundlesListH}
            />
          </Pane>
          <Pane title="Detail" flexBasis="40%">
            <DescriptionList items={detail.slice(0, detailMax)} gutter={9} />
          </Pane>
        </Box>
      </Box>
      {/* Reserved 1-row banner slot — always present (empty when there's no
          notice) so the frame height never changes and the footer stays put. */}
      <Box height={1} flexShrink={0} overflow="hidden">
        {banner ? <Banner tone="info" text={banner} /> : null}
      </Box>
      <Box flexShrink={0} flexDirection="column">
        <Footer keys={FOOTER_KEYS} marginTop={0} />
      </Box>
    </Box>
  );
}
