/**
 * PauseScreen — a "blocked on a manual action, press Enter when done" pause
 * (e.g. syncthing: approve this device on the hub, THEN continue). This is an
 * ACKNOWLEDGE, not an input — so it is a blink-tui <Dialog> with a waiting
 * <Spinner>, exactly as the framework prescribes ("the pause prompt itself is an
 * app Dialog, not a [field]"), NOT a Form field with a text box.
 *
 * Keys: Enter continue · Esc cancel (a pause never aborts the caller — bash maps
 * both to "carry on", Esc just stops waiting).
 */
import { Box, Text, useInput } from 'ink';
import { Dialog, Spinner, type DialogAction } from '@henryavila/blink-tui';

const ACTIONS: DialogAction[] = [
  { key: 'enter', label: 'continue' },
  { key: 'esc', label: 'skip' },
];

export interface PauseScreenProps {
  label: string;
  /** true = Enter (continue), false = Esc (skip waiting). */
  onDone: (ok: boolean) => void;
}

export function PauseScreen({ label, onDone }: PauseScreenProps) {
  useInput((_input, key) => {
    if (key.return) return onDone(true);
    if (key.escape) return onDone(false);
  });

  return (
    <Box flexDirection="column">
      <Dialog title="action needed" tone="default" actions={ACTIONS} width={72}>
        <Box flexDirection="column">
          <Text>{label}</Text>
          <Box marginTop={1}>
            <Spinner />
            <Text> waiting — press Enter when it's done</Text>
          </Box>
        </Box>
      </Dialog>
    </Box>
  );
}
