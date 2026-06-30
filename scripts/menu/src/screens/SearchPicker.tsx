/**
 * SearchPicker — the realtime-filter project picker for `mesh ai`. herdr has no
 * fuzzy discovery of repos on disk, so this is the blink front-end that fills
 * it: type any part of a name, the list filters live, Enter hands the chosen
 * row back to bash (the runner then focuses/creates the herdr workspace).
 *
 * Option A (today): COMPOSED from blink-tui v0.2.0 primitives already exported —
 * <Input> (the query) + <List> (windowed, navigable results) + a one-line
 * substring filter here. No new blink FieldKind (that is the future option B).
 *
 * BLINK-ONLY visuals (Header/Input/List/Footer); Ink <Box> is layout, useInput
 * is the app's own keymap (blink never embeds one). Driven from bash via
 * `node index.js ai-pick --in <candidates> --out <file>`.
 *
 * Keys: type / Backspace filter · ↑↓ move · Enter open focused · Ctrl-N open a
 * NEW agent in the focused repo (a fresh tab if it is already open) · Esc cancel.
 */
import { useEffect, useMemo, useState } from 'react';
import { Box, useInput } from 'ink';
import {
  Header,
  Footer,
  Input,
  List,
  useListNavigation,
  type ListRowData,
  type HotkeyDef,
} from '@henryavila/blink-tui';

export interface AiItem {
  /** Unique id (tab_id, else wsid, else path) — React key + focus lookups. */
  id: string;
  label: string;
  /** Project directory: the repo path, or an open workspace's pane cwd. */
  path: string;
  /** herdr workspace_id when already open (→ focus); '' for a closed repo (→ create). */
  wsid: string;
  /** herdr agent_status for an open workspace/tab; '' for a closed repo. */
  status: string;
  /** herdr tab_id when this row is a specific tab inside a workspace; '' otherwise. */
  tabid: string;
  /** True iff already open in herdr (a workspace or one of its tabs). */
  open: boolean;
  /** Original `label<TAB>path<TAB>wsid<TAB>status<TAB>tabid` line, handed back verbatim. */
  raw: string;
}

/** Parse the runner's candidate file (one
 *  `label<TAB>path<TAB>wsid<TAB>status<TAB>tabid` per line) into items. Blank and
 *  label-less rows are dropped. Pure. */
export function parseCandidates(text: string): AiItem[] {
  return text
    .split('\n')
    .map((l) => l.replace(/\r$/, ''))
    .filter((l) => l.length > 0)
    .map((raw) => {
      const parts = raw.split('\t');
      const label = parts[0] ?? '';
      const path = parts[1] ?? '';
      const wsid = parts[2] ?? '';
      const status = parts[3] ?? '';
      const tabid = parts[4] ?? '';
      return { id: tabid || wsid || path, label, path, wsid, status, tabid, open: wsid.length > 0, raw };
    })
    .filter((it) => it.label.length > 0);
}

/** Case-insensitive substring filter on the label (any position). Empty query →
 *  everything. Pure. */
export function filterItems(items: AiItem[], query: string): AiItem[] {
  const q = query.trim().toLowerCase();
  if (!q) return items;
  return items.filter((it) => it.label.toLowerCase().includes(q));
}

/** Abbreviate $HOME to `~` for display (routing always uses the raw path). Pure. */
export function abbrevHome(path: string, home = process.env.HOME ?? ''): string {
  if (home && (path === home || path.startsWith(`${home}/`))) return `~${path.slice(home.length)}`;
  return path;
}

/** The right-aligned aside for a row: open workspaces read `herdr <status> · <dir>`
 *  (so you see it is live AND which project it is); closed repos read the dir. Pure. */
export function rowMeta(it: AiItem): string {
  const dir = abbrevHome(it.path);
  if (it.open) {
    const status = it.status || 'idle';
    return dir ? `herdr ${status} · ${dir}` : `herdr ${status}`;
  }
  return dir;
}

/** What to do with the chosen row: `open` focuses/opens the primary target;
 *  `new` opens ANOTHER agent in the project (a fresh tab if it is already open). */
export type AiAction = 'open' | 'new';

export interface SearchPickerProps {
  items: AiItem[];
  /** Called with the chosen item's raw line + the action (Enter → open, Ctrl-N →
   *  new), or (null) on cancel. */
  onDone: (raw: string | null, action?: AiAction) => void;
}

export function SearchPicker({ items, onDone }: SearchPickerProps) {
  const [query, setQuery] = useState('');
  const filtered = useMemo(() => filterItems(items, query), [items, query]);
  const ids = useMemo(() => filtered.map((it) => it.id), [filtered]);

  // Controlled focus: keep it inside the current (filtered) id set — when the
  // filter narrows and the focused row disappears, snap to the first match.
  const [focusId, setFocusId] = useState<string | null>(ids[0] ?? null);
  useEffect(() => {
    if (focusId === null || !ids.includes(focusId)) setFocusId(ids[0] ?? null);
  }, [ids, focusId]);
  const nav = useListNavigation({ ids, focusedId: focusId, onFocusChange: setFocusId });

  // Enter opens/focuses the primary target; Ctrl-N opens a NEW agent in the same
  // repo (a fresh tab when its workspace is already open) — both act on the row
  // currently focused.
  const choose = (action: AiAction) => {
    const c = filtered.find((it) => it.id === focusId) ?? filtered[0];
    onDone(c ? c.raw : null, action);
  };

  useInput((input, key) => {
    if (key.escape) return onDone(null);
    if (key.return) return choose('open');
    if (key.ctrl && input === 'n') return choose('new');
    if (key.downArrow) return nav.focusNext();
    if (key.upArrow) return nav.focusPrev();
    if (key.backspace || key.delete) return setQuery((q) => q.slice(0, -1));
    if (input.length > 0 && !key.ctrl && !key.meta && !key.tab) {
      setQuery((q) => q + input);
    }
  });

  const rows: ListRowData[] = filtered.map((it) => ({
    id: it.id,
    label: it.label,
    meta: rowMeta(it),
  }));

  const keys: HotkeyDef[] = [
    { k: 'type', desc: 'filter' },
    { k: '↑↓', desc: 'move' },
    { k: 'enter', desc: 'open' },
    { k: '^n', desc: 'new' },
    { k: 'esc', desc: 'cancel' },
  ];

  return (
    <Box flexDirection="column">
      <Header title="mesh ai" subtitle="open in herdr" right={`${filtered.length}/${items.length}`} />
      <Input title="search" value={query} placeholder="type any part of a repo name…" focused />
      <List rows={rows} focusedId={focusId} height={12} />
      <Footer keys={keys} />
    </Box>
  );
}
