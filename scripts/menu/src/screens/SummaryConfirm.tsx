/**
 * SummaryConfirm (T-306) — the apply plan: what installs, what stays, what is
 * removed, then confirm.
 *
 * BLINK-ONLY: a blink <List> renders the delta (action carried as a `state`
 * intent + a `meta` label — install=pending, remove=warn, keep=installed muted);
 * Header/Footer/Banner are blink; Ink <Box> is layout.
 *
 * Keys: ↑/↓ scroll · y / Enter apply · e / Esc back to picker · q quit.
 */
import { Box, useInput } from 'ink';
import {
  Header,
  Footer,
  Pane,
  List,
  Banner,
  useListNavigation,
  useStdoutDimensions,
  type ListRowData,
  type HotkeyDef,
} from '@henryavila/blink-tui';
import { resolveDomain } from '../glyphs.js';
import type { BundleRef } from '../types.js';
import type { Delta } from '../core/delta.js';

const FOOTER_KEYS: HotkeyDef[] = [
  { k: 'y', desc: 'apply' },
  { k: 'e', desc: 'back' },
  { k: 'q', desc: 'quit' },
];

export interface SummaryConfirmProps {
  delta: Delta;
  index: Map<string, BundleRef>;
  /** True when the engine will apply (vs the menu only writing selections). */
  applyLabel: string;
  onConfirm: () => void;
  onBack: () => void;
  onQuit: () => void;
}

function row(key: string, kind: 'install' | 'remove' | 'keep', index: Map<string, BundleRef>): ListRowData {
  const ref = index.get(key);
  const domain = ref ? resolveDomain(ref.bundle.icon_name) : undefined;
  const label = ref ? `${ref.bundle.label}  ·  ${key}` : key;
  if (kind === 'install') return { id: `i:${key}`, label, state: 'pending', meta: 'install', domain };
  if (kind === 'remove') return { id: `r:${key}`, label, state: 'warn', meta: 'remove', domain };
  return { id: `k:${key}`, label, state: 'installed', meta: 'keep', domain, muted: true };
}

export function SummaryConfirm(props: SummaryConfirmProps) {
  const { delta, index } = props;
  const { rows: rawRows } = useStdoutDimensions();
  const termRows = rawRows >= 10 ? rawRows : 24; // guard a bad/0 resize reading

  const rows: ListRowData[] = [
    ...delta.install.map((k) => row(k, 'install', index)),
    ...delta.remove.map((k) => row(k, 'remove', index)),
    ...delta.keep.map((k) => row(k, 'keep', index)),
  ];
  const nav = useListNavigation({ ids: rows.map((r) => r.id) });

  useInput((input, key) => {
    if (key.upArrow || input === 'k') return nav.focusPrev();
    if (key.downArrow || input === 'j') return nav.focusNext();
    if (input === 'y' || key.return) return props.onConfirm();
    if (input === 'e' || key.escape) return props.onBack();
    if (input === 'q') return props.onQuit();
  });

  const summary = `+${delta.install.length}  ~${delta.keep.length}  -${delta.remove.length}`;
  const nothing = delta.install.length === 0 && delta.remove.length === 0;
  // Same full-screen contract as TopicPicker: pin to rows-1, fixed header/banner/
  // footer bands, the list pane flexes. The banner row is reserved even when
  // empty so the frame height stays constant and the footer never drifts.
  const screenH = Math.max(8, termRows - 1);
  const innerHeight = Math.max(6, screenH - 3); // header (1) + banner (1) + footer (1)

  return (
    <Box flexDirection="column" height={screenH}>
      <Box flexShrink={0} flexDirection="column">
        <Header title="apply plan" subtitle={props.applyLabel} right={summary} />
      </Box>
      <Box flexGrow={1} minHeight={0} overflow="hidden" flexDirection="column">
        <Pane title="install · keep · remove" tone="focus" flexGrow={1}>
          <List rows={rows} focusedId={nav.focusedId} height={innerHeight - 2} />
        </Pane>
      </Box>
      <Box height={1} flexShrink={0} overflow="hidden">
        {nothing ? <Banner tone="info" text="No install/remove changes — selection matches current state." /> : null}
      </Box>
      <Box flexShrink={0} flexDirection="column">
        <Footer keys={FOOTER_KEYS} marginTop={0} right={`${rows.length} bundles`} />
      </Box>
    </Box>
  );
}
