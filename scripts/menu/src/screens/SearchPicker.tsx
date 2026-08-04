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
 * Keys: type / Backspace filter · ↑↓ move · Enter open focused with the saved
 * default · Tab actions for the focused row · Ctrl-P local preferences · Esc.
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

export function preferenceSummary(defaultAgent: string, defaultAction: string, openExisting: string): string {
  return `agent=${defaultAgent} · open=${defaultAction} · open existing=${openExisting}`;
}

/** What to do with the chosen row:
 *  `open` uses the saved default; `new` opens another default agent; `shell`
 *  opens the directory without running an agent; `agent:<name>` forces a named
 *  agent; `pref:<field>:<value>` updates local machine preferences. */
export type AiAction =
  | 'open'
  | 'new'
  | 'shell'
  | `agent:${string}`
  | `pref:${string}:${string}`;

type PickerMode = 'search' | 'actions' | 'prefs';

interface MenuItem {
  id: string;
  label: string;
  meta: string;
  action: AiAction;
}

export interface SearchPickerProps {
  items: AiItem[];
  /** Called with the chosen item's raw line + the action (Enter → open, Ctrl-N →
   *  new), or (null) on cancel. */
  onDone: (raw: string | null, action?: AiAction) => void;
}

export function SearchPicker({ items, onDone }: SearchPickerProps) {
  const [query, setQuery] = useState('');
  const [mode, setMode] = useState<PickerMode>('search');
  const filtered = useMemo(() => filterItems(items, query), [items, query]);
  const searchIds = useMemo(() => filtered.map((it) => it.id), [filtered]);

  // Controlled focus: keep it inside the current (filtered) id set — when the
  // filter narrows and the focused row disappears, snap to the first match.
  const [searchFocusId, setSearchFocusId] = useState<string | null>(searchIds[0] ?? null);
  useEffect(() => {
    if (searchFocusId === null || !searchIds.includes(searchFocusId)) setSearchFocusId(searchIds[0] ?? null);
  }, [searchIds, searchFocusId]);

  const selected = filtered.find((it) => it.id === searchFocusId) ?? filtered[0];

  const actionItems: MenuItem[] = [
    { id: 'open', label: 'Open with default', meta: selected?.label ?? '', action: 'open' },
    { id: 'agent-grok', label: 'Open with Grok', meta: 'one time', action: 'agent:grok' },
    { id: 'agent-claude', label: 'Open with Claude', meta: 'one time', action: 'agent:claude' },
    { id: 'agent-codex', label: 'Open with Codex', meta: 'one time', action: 'agent:codex' },
    { id: 'shell', label: 'Open shell', meta: 'directory only', action: 'shell' },
    { id: 'new', label: 'New default agent tab', meta: 'fresh tab if open', action: 'new' },
  ];

  const defaultAgent = process.env.MESH_AI_DEFAULT_AGENT || process.env.MESH_AI_AGENT || 'claude';
  const defaultAction = process.env.MESH_AI_DEFAULT_ACTION || 'agent';
  const openExisting = process.env.MESH_AI_OPEN_EXISTING || 'focus';
  const currentLabel = (label: string, current: boolean) => (current ? `${label} (current)` : label);
  const prefItems: MenuItem[] = [
    { id: 'pref-agent-grok', label: currentLabel('Default agent: Grok', defaultAgent === 'grok'), meta: '', action: 'pref:agent:grok' },
    { id: 'pref-agent-claude', label: currentLabel('Default agent: Claude', defaultAgent === 'claude'), meta: '', action: 'pref:agent:claude' },
    { id: 'pref-agent-codex', label: currentLabel('Default agent: Codex', defaultAgent === 'codex'), meta: '', action: 'pref:agent:codex' },
    { id: 'pref-action-agent', label: currentLabel('Enter opens agent', defaultAction === 'agent'), meta: '', action: 'pref:action:agent' },
    { id: 'pref-action-shell', label: currentLabel('Enter opens shell', defaultAction === 'shell'), meta: '', action: 'pref:action:shell' },
    { id: 'pref-open-focus', label: currentLabel('Open existing: focus', openExisting === 'focus'), meta: '', action: 'pref:open:focus' },
    { id: 'pref-open-new', label: currentLabel('Open existing: new tab', openExisting === 'new'), meta: '', action: 'pref:open:new' },
  ];

  const menuItems = mode === 'prefs' ? prefItems : actionItems;
  const menuIds = useMemo(() => menuItems.map((it) => it.id), [menuItems]);
  const [menuFocusId, setMenuFocusId] = useState<string | null>(menuIds[0] ?? null);
  useEffect(() => {
    if (menuFocusId === null || !menuIds.includes(menuFocusId)) setMenuFocusId(menuIds[0] ?? null);
  }, [menuIds, menuFocusId]);

  const searchNav = useListNavigation({ ids: searchIds, focusedId: searchFocusId, onFocusChange: setSearchFocusId });
  const menuNav = useListNavigation({ ids: menuIds, focusedId: menuFocusId, onFocusChange: setMenuFocusId });

  // Enter in search opens the primary target with the saved default. The action
  // and preferences menus return explicit actions for the same focused row.
  const choose = (action: AiAction) => {
    onDone(selected ? selected.raw : null, action);
  };

  const chooseMenu = () => {
    const item = menuItems.find((it) => it.id === menuFocusId) ?? menuItems[0];
    if (item) choose(item.action);
  };

  useInput((input, key) => {
    if (mode !== 'search') {
      if (key.escape || key.tab) return setMode('search');
      if (key.return) return chooseMenu();
      if (key.downArrow) return menuNav.focusNext();
      if (key.upArrow) return menuNav.focusPrev();
      return;
    }

    if (key.escape) return onDone(null);
    if (key.return) return choose('open');
    if (key.tab) {
      setMode('actions');
      setMenuFocusId(actionItems[0]?.id ?? null);
      return;
    }
    if (key.ctrl && input === 'p') {
      setMode('prefs');
      setMenuFocusId(prefItems[0]?.id ?? null);
      return;
    }
    if (key.downArrow) return searchNav.focusNext();
    if (key.upArrow) return searchNav.focusPrev();
    if (key.backspace || key.delete) return setQuery((q) => q.slice(0, -1));
    if (input.length > 0 && !key.ctrl && !key.meta && !key.tab) {
      setQuery((q) => q + input);
    }
  });

  const rows: ListRowData[] =
    mode === 'search'
      ? filtered.map((it) => ({
          id: it.id,
          label: it.label,
          meta: rowMeta(it),
        }))
      : menuItems.map((it) => ({
          id: it.id,
          label: it.label,
          meta: it.meta,
        }));

  const keys: HotkeyDef[] =
    mode === 'search'
      ? [
          { k: 'type', desc: 'filter' },
          { k: '↑↓', desc: 'move' },
          { k: 'enter', desc: 'default' },
          { k: 'tab', desc: 'actions' },
          { k: '^p', desc: 'prefs' },
          { k: 'esc', desc: 'cancel' },
        ]
      : [
          { k: '↑↓', desc: 'move' },
          { k: 'enter', desc: 'select' },
          { k: 'tab/esc', desc: 'back' },
        ];

  const title = mode === 'prefs' ? 'mesh ai preferences' : mode === 'actions' ? selected?.label ?? 'actions' : 'mesh ai';
  const subtitle =
    mode === 'search'
      ? 'open in herdr'
      : mode === 'actions'
        ? 'choose action'
        : preferenceSummary(defaultAgent, defaultAction, openExisting);
  const focusedId = mode === 'search' ? searchFocusId : menuFocusId;
  const right = mode === 'search' ? `${filtered.length}/${items.length}` : `${menuItems.length}`;

  return (
    <Box flexDirection="column">
      <Header title={title} subtitle={subtitle} right={right} />
      {mode === 'search' && <Input title="search" value={query} placeholder="type any part of a repo name…" focused />}
      <List rows={rows} focusedId={focusedId} height={12} />
      <Footer keys={keys} />
    </Box>
  );
}
