/**
 * ServicesPicker — the realtime-filter service picker for `mesh services` (no
 * args). Mirrors SearchPicker: blink <Input> (the query) + <List> (windowed,
 * navigable) + a one-line substring filter here. No new blink FieldKind (the
 * 3rd-repo package is untouched). Fed from bash via
 * `node index.js services --in <rows> --out <file>`, where the rows are the
 * `mesh services list --porcelain` lines:
 *   id|display|aliases|owner|kind|scope|target|active|enabled
 *
 * BLINK-ONLY visuals (Header/Input/List/Footer); Ink <Box> is layout, useInput
 * is the app's own keymap. This is the first of the two screens (the second is
 * ServiceActions); ServicesFlow (services-main) orchestrates the transition.
 *
 * Keys: type / Backspace filter · ↑↓ move · Enter select · Esc cancel.
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

export interface ServiceItem {
  /** Registry id — React key, focus lookups, and the name handed back to bash. */
  id: string;
  display: string;
  aliases: string;
  owner: string;
  /** Backend: systemd | brew | launchd. */
  kind: string;
  /** systemd scope (system|user); empty for brew/launchd. */
  scope: string;
  /** The resolved unit / formula / label. */
  target: string;
  /** Running now: on | off | unknown. */
  active: string;
  /** Autostarts at boot: on | off | unknown. */
  enabled: string;
  /** The original porcelain line, verbatim. */
  raw: string;
}

/** Parse `mesh services list --porcelain` rows (one
 *  `id|display|aliases|owner|kind|scope|target|active|enabled` per line) into
 *  items. Blank and id-less rows are dropped. Pure. */
export function parseServices(text: string): ServiceItem[] {
  return text
    .split('\n')
    .map((l) => l.replace(/\r$/, ''))
    .filter((l) => l.length > 0)
    .map((raw) => {
      const p = raw.split('|');
      return {
        id: p[0] ?? '',
        display: p[1] ?? '',
        aliases: p[2] ?? '',
        owner: p[3] ?? '',
        kind: p[4] ?? '',
        scope: p[5] ?? '',
        target: p[6] ?? '',
        active: p[7] ?? '',
        enabled: p[8] ?? '',
        raw,
      };
    })
    .filter((it) => it.id.length > 0);
}

/** Case-insensitive substring filter on id + display + aliases. Empty query →
 *  everything. Pure. */
export function filterServices(items: ServiceItem[], query: string): ServiceItem[] {
  const q = query.trim().toLowerCase();
  if (!q) return items;
  return items.filter(
    (it) =>
      it.id.toLowerCase().includes(q) ||
      it.display.toLowerCase().includes(q) ||
      it.aliases.toLowerCase().includes(q),
  );
}

/** Human label for the active bit. Pure. */
export function activeBadge(active: string): string {
  return active === 'on' ? 'running' : active === 'off' ? 'stopped' : '?';
}

/** Human label for the enabled (boot) bit. Pure. */
export function enabledBadge(enabled: string): string {
  return enabled === 'on' ? 'on-boot' : enabled === 'off' ? 'no-boot' : '?';
}

/** Right-aligned aside for a row: both badges + backend + owner. Pure. */
export function serviceMeta(it: ServiceItem): string {
  return `${activeBadge(it.active)} · ${enabledBadge(it.enabled)} · ${it.kind} · ${it.owner}`;
}

export interface ServicesPickerProps {
  items: ServiceItem[];
  /** Called with the chosen service, or null on cancel (Esc). */
  onPick: (item: ServiceItem | null) => void;
}

export function ServicesPicker({ items, onPick }: ServicesPickerProps) {
  const [query, setQuery] = useState('');
  const filtered = useMemo(() => filterServices(items, query), [items, query]);
  const ids = useMemo(() => filtered.map((it) => it.id), [filtered]);

  // Controlled focus: keep it inside the current (filtered) id set.
  const [focusId, setFocusId] = useState<string | null>(ids[0] ?? null);
  useEffect(() => {
    if (focusId === null || !ids.includes(focusId)) setFocusId(ids[0] ?? null);
  }, [ids, focusId]);
  const nav = useListNavigation({ ids, focusedId: focusId, onFocusChange: setFocusId });

  useInput((input, key) => {
    if (key.escape) return onPick(null);
    if (key.return) {
      const chosen = filtered.find((it) => it.id === focusId) ?? filtered[0];
      return onPick(chosen ?? null);
    }
    if (key.downArrow) return nav.focusNext();
    if (key.upArrow) return nav.focusPrev();
    if (key.backspace || key.delete) return setQuery((q) => q.slice(0, -1));
    if (input.length > 0 && !key.ctrl && !key.meta && !key.tab) {
      setQuery((q) => q + input);
    }
  });

  const rows: ListRowData[] = filtered.map((it) => ({
    id: it.id,
    label: it.display,
    meta: serviceMeta(it),
  }));

  const keys: HotkeyDef[] = [
    { k: 'type', desc: 'filter' },
    { k: '↑↓', desc: 'move' },
    { k: 'enter', desc: 'select' },
    { k: 'esc', desc: 'cancel' },
  ];

  return (
    <Box flexDirection="column">
      <Header title="mesh services" subtitle="active × enabled" right={`${filtered.length}/${items.length}`} />
      <Input title="filter" value={query} placeholder="type part of a service name…" focused />
      <List rows={rows} focusedId={focusId} height={12} />
      <Footer keys={keys} />
    </Box>
  );
}
