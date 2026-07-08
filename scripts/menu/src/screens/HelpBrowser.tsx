/**
 * HelpBrowser — searchable, read-only command help for `mesh help`.
 *
 * Composed from blink primitives already used by SearchPicker/ServicesPicker:
 * Header, Input, List, Pane, DescriptionList, Banner and Footer. The app owns
 * the keymap and keeps command execution out of the TUI; detail text is
 * precomputed by the shell runner.
 */
import { useEffect, useMemo, useState } from 'react';
import { Box, Text, useInput } from 'ink';
import {
  Header,
  Footer,
  Input,
  List,
  Pane,
  DescriptionList,
  Banner,
  useListNavigation,
  useStdoutDimensions,
  type DescriptionItem,
  type HotkeyDef,
  type ListRowData,
} from '@henryavila/blink-tui';

export interface HelpCommand {
  name: string;
  summary: string;
  group: string;
  origin: string;
  visibility: string;
  fanout: string;
}

export function parseCommandsTsv(text: string): HelpCommand[] {
  return text
    .split('\n')
    .map((l) => l.replace(/\r$/, ''))
    .filter((l) => l.length > 0)
    .map((raw) => {
      const p = raw.split('\t');
      return {
        name: p[0] ?? '',
        summary: p[1] ?? '',
        group: p[2] ?? '',
        origin: p[3] ?? '',
        visibility: p[4] ?? '',
        fanout: p[5] ?? '',
      };
    })
    .filter((cmd) => cmd.name.length > 0);
}

export function filterCommands(commands: HelpCommand[], query: string): HelpCommand[] {
  const q = query.trim().toLowerCase();
  if (!q) return commands;
  return commands.filter(
    (cmd) =>
      cmd.name.toLowerCase().includes(q) ||
      cmd.summary.toLowerCase().includes(q) ||
      cmd.group.toLowerCase().includes(q),
  );
}

function commandMeta(cmd: HelpCommand): string {
  return cmd.fanout === 'allowed' ? 'fanout' : 'local';
}

function detailItems(cmd: HelpCommand): DescriptionItem[] {
  return [
    { term: 'command', value: `mesh ${cmd.name}` },
    { term: 'summary', value: cmd.summary, muted: true },
    { term: 'group', value: cmd.group },
    { term: 'fanout', value: cmd.fanout === 'allowed' ? 'allowed' : 'none' },
  ];
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}

function linesFor(cmd: HelpCommand, details: Map<string, string[]>): string[] {
  const lines = details.get(cmd.name)?.filter((line, idx, arr) => line.length > 0 || idx < arr.length - 1);
  if (lines && lines.length > 0) return lines;
  return [`mesh ${cmd.name}`, '', cmd.summary];
}

export interface HelpBrowserProps {
  commands: HelpCommand[];
  details: Map<string, string[]>;
  selected?: string;
  onExit: (code?: number) => void;
}

const FOOTER_KEYS: HotkeyDef[] = [
  { k: 'type', desc: 'filter' },
  { k: '↑↓', desc: 'move' },
  { k: 'pgup', desc: 'up' },
  { k: 'pgdn', desc: 'down' },
  { k: 'q', desc: 'quit' },
];

export function HelpBrowser({ commands, details, selected, onExit }: HelpBrowserProps) {
  const [query, setQuery] = useState('');
  const filtered = useMemo(() => filterCommands(commands, query), [commands, query]);
  const ids = useMemo(() => filtered.map((cmd) => cmd.name), [filtered]);
  const initial = selected && commands.some((cmd) => cmd.name === selected) ? selected : ids[0] ?? null;
  const [focusId, setFocusId] = useState<string | null>(initial);
  const [detailOffset, setDetailOffset] = useState(0);
  const { rows: rawRows, columns: rawCols } = useStdoutDimensions();
  const rows = rawRows >= 10 ? rawRows : 24;
  const cols = rawCols >= 50 ? rawCols : 100;
  const screenH = Math.max(9, rows - 1);
  const listH = Math.max(4, screenH - 6);
  const leftW = Math.max(24, Math.min(36, Math.round(cols * 0.34)));
  const detailH = Math.max(4, screenH - 11);
  const detailW = Math.max(20, cols - leftW - 8);

  useEffect(() => {
    if (focusId === null || !ids.includes(focusId)) setFocusId(ids[0] ?? null);
  }, [ids, focusId]);
  useEffect(() => setDetailOffset(0), [focusId]);

  const nav = useListNavigation({ ids, focusedId: focusId, onFocusChange: setFocusId });
  const focused = commands.find((cmd) => cmd.name === focusId) ?? filtered[0] ?? commands[0];
  const detailLines = focused ? linesFor(focused, details) : [];
  const maxOffset = Math.max(0, detailLines.length - detailH);
  const effectiveOffset = clamp(detailOffset, 0, maxOffset);
  const visibleDetail = detailLines.slice(effectiveOffset, effectiveOffset + detailH);

  useInput((input, key) => {
    if (key.escape || input === 'q') return onExit(0);
    if (key.downArrow) return nav.focusNext();
    if (key.upArrow) return nav.focusPrev();
    if (key.pageDown) return setDetailOffset((n) => clamp(n + Math.max(1, detailH - 1), 0, maxOffset));
    if (key.pageUp) return setDetailOffset((n) => clamp(n - Math.max(1, detailH - 1), 0, maxOffset));
    if (key.backspace || key.delete) return setQuery((q) => q.slice(0, -1));
    if (input.length > 0 && !key.ctrl && !key.meta && !key.tab && input !== '\r') {
      setQuery((q) => q + input);
    }
  });

  const rowsData: ListRowData[] = filtered.map((cmd) => ({
    id: cmd.name,
    label: cmd.name,
    meta: commandMeta(cmd),
    muted: cmd.name !== focusId && cmd.fanout !== 'allowed',
  }));

  if (commands.length === 0) {
    return (
      <Box flexDirection="column">
        <Header title="mesh help" subtitle="command browser" />
        <Banner tone="warn" text="No registered commands." />
        <Footer keys={[{ k: 'q', desc: 'quit' }]} />
      </Box>
    );
  }

  return (
    <Box flexDirection="column" height={screenH}>
      <Header title="mesh help" subtitle="command browser" right={`${filtered.length}/${commands.length}`} />
      <Input title="filter" value={query} placeholder="type command, group or summary…" focused />
      <Box flexDirection="row" flexGrow={1} minHeight={0} overflow="hidden">
        <Pane title="Commands" tone="focus" width={leftW} flexGrow={0}>
          <List rows={rowsData} focusedId={focusId} height={listH} />
        </Pane>
        <Box flexDirection="column" flexGrow={1}>
          <Pane title={focused?.name ?? 'Detail'} flexGrow={1}>
            {focused ? <DescriptionList items={detailItems(focused)} gutter={9} /> : null}
            <Box flexDirection="column" marginTop={1}>
              {visibleDetail.map((line, i) => (
                <Text key={`${effectiveOffset + i}:${line}`} wrap="truncate">
                  {line.slice(0, detailW)}
                </Text>
              ))}
            </Box>
          </Pane>
        </Box>
      </Box>
      <Box height={1} flexShrink={0} overflow="hidden">
        {maxOffset > 0 ? (
          <Banner tone="info" text={`${effectiveOffset + 1}-${Math.min(detailLines.length, effectiveOffset + detailH)} / ${detailLines.length}`} />
        ) : null}
      </Box>
      <Footer keys={FOOTER_KEYS} marginTop={0} right={focused ? `mesh ${focused.name} --help` : undefined} />
    </Box>
  );
}
