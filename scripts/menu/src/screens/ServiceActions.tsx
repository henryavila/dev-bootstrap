/**
 * ServiceActions — the second screen of `mesh services` (no args): the
 * context-aware actions for the picked service. Hides `start` when the service
 * is already running and offers stop/restart; offers `enable` XOR `disable` by
 * the boot bit. Composed from blink <List> + useListNavigation + the app's own
 * useInput (no new FieldKind). Enter runs the verb; Esc goes back to the list.
 *
 * Keys: ↑↓ move · Enter run · Esc back.
 */
import { useState } from 'react';
import { Box, useInput } from 'ink';
import { Header, Footer, List, useListNavigation, type ListRowData, type HotkeyDef } from '@henryavila/blink-tui';
import { activeBadge, enabledBadge, type ServiceItem } from './ServicesPicker.js';

export interface ServiceAction {
  verb: string;
  desc: string;
}

/** Context-aware actions for a service's two bits. Pure.
 *  active: on → stop+restart · off → start · unknown → start+stop+restart;
 *  enabled: on → disable · off → enable · unknown → enable+disable. */
export function actionsFor(item: ServiceItem): ServiceAction[] {
  const acts: ServiceAction[] = [];
  if (item.active === 'on') {
    acts.push({ verb: 'stop', desc: 'stop now' }, { verb: 'restart', desc: 'restart now' });
  } else if (item.active === 'off') {
    acts.push({ verb: 'start', desc: 'start now' });
  } else {
    acts.push(
      { verb: 'start', desc: 'start now' },
      { verb: 'stop', desc: 'stop now' },
      { verb: 'restart', desc: 'restart now' },
    );
  }
  if (item.enabled === 'on') {
    acts.push({ verb: 'disable', desc: 'stop starting at boot' });
  } else if (item.enabled === 'off') {
    acts.push({ verb: 'enable', desc: 'start at boot' });
  } else {
    acts.push({ verb: 'enable', desc: 'start at boot' }, { verb: 'disable', desc: 'stop starting at boot' });
  }
  return acts;
}

export interface ServiceActionsProps {
  service: ServiceItem;
  /** Called with the chosen verb, or null to go back to the list (Esc). */
  onAction: (verb: string | null) => void;
}

export function ServiceActions({ service, onAction }: ServiceActionsProps) {
  const actions = actionsFor(service);
  const ids = actions.map((a) => a.verb);
  const [focusId, setFocusId] = useState<string | null>(ids[0] ?? null);
  const nav = useListNavigation({ ids, focusedId: focusId, onFocusChange: setFocusId });

  useInput((_input, key) => {
    if (key.escape) return onAction(null);
    if (key.return) return onAction(focusId);
    if (key.downArrow) return nav.focusNext();
    if (key.upArrow) return nav.focusPrev();
  });

  const rows: ListRowData[] = actions.map((a) => ({ id: a.verb, label: a.verb, meta: a.desc }));
  const keys: HotkeyDef[] = [
    { k: '↑↓', desc: 'move' },
    { k: 'enter', desc: 'run' },
    { k: 'esc', desc: 'back' },
  ];

  return (
    <Box flexDirection="column">
      <Header
        title={service.display}
        subtitle={`${activeBadge(service.active)} · ${enabledBadge(service.enabled)}`}
        right={service.kind}
      />
      <List rows={rows} focusedId={focusId} height={8} />
      <Footer keys={keys} />
    </Box>
  );
}
