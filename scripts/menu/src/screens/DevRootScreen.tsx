/**
 * DevRootScreen — collects CODE_DIR, the per-host "dev root": the directory your
 * repos live in, exported into the shell (auto-cd + tmux project shortcuts in
 * mesh-identity) and used as the web stack's serving root when that's installed.
 *
 * It is shown up-front (the wizard's first screen) so the value is collected
 * once, like IdentityOnboarding ports the apply.sh /dev/tty prompt into the menu
 * instead of the engine falling back. The OLD whiptail menu asked this (gated on
 * the web stack); the rebuild dropped it, so nothing populated CODE_DIR and the
 * shell auto-cd silently fell back to $HOME — this screen restores it, universal
 * (not web-gated) per the chosen framing.
 *
 * It writes a single env to params.env: CODE_DIR=<resolved absolute path>. The
 * value is RESOLVED here (the app owns os.homedir/env, blink stays no-I/O) so
 * params.env carries an absolute path bash sources verbatim — never a literal
 * `~` (which quoteParam would quote, defeating tilde expansion). setup.sh then
 * upserts it into ~/.config/mesh/config.env for the interactive shell to read.
 *
 * BLINK-ONLY: blink Form (one `path` field) + Header/Footer/Banner; the path
 * field's preview + status are app-fed (blink renders, the app computes) per the
 * v0.2.0 `path` kind contract. Ink <Box> is layout only.
 *
 * Keys: type / Backspace edit · Enter save (resolves + persists) · Esc skip
 * (keep the current/default value, advance without writing).
 */
import { homedir } from 'node:os';
import { statSync } from 'node:fs';
import { useState } from 'react';
import { Box, useInput } from 'ink';
import {
  Header,
  Footer,
  Pane,
  Form,
  Banner,
  type FieldSpec,
  type HotkeyDef,
  type PathStatus,
} from '@henryavila/blink-tui';

/** The single env this screen resolves — the dev-root contract (setup.sh + the
 *  web topic's deploy-env + mesh-identity shell/aliases.sh all read CODE_DIR). */
export const CODE_DIR_ENV = 'CODE_DIR';

const FOOTER_KEYS: HotkeyDef[] = [
  { k: 'enter', desc: 'save' },
  { k: 'esc', desc: 'skip' },
];

/**
 * Resolve a typed path to an absolute one, app-side (blink does no I/O):
 *   ''        → home/code (the default dev root, `~/code`)
 *   '~'       → home
 *   '~/x'     → home/x
 *   '$HOME/x' → home/x
 *   '/abs'    → as-is
 *   'rel'     → home/rel (a bare name is taken under the dev root's parent, home)
 */
export function resolveDevRoot(raw: string, home: string = homedir()): string {
  const v = raw.trim();
  if (v === '') return home + '/code'; // unset → the default dev root
  if (v === '~' || v === '$HOME') return home;
  if (v.startsWith('~/')) return home + v.slice(1);
  if (v.startsWith('$HOME/')) return home + v.slice(5);
  if (v.startsWith('/')) return v;
  return home + '/' + v;
}

/** Presentational status for the resolved path — app computes (owns fs.stat),
 *  blink maps the intent name → glyph/colour. Never throws. */
export function devRootStatus(resolved: string): PathStatus {
  try {
    return statSync(resolved).isDirectory() ? 'exists' : 'invalid';
  } catch {
    return 'create'; // ENOENT (or unreadable) → will be created on first use
  }
}

export interface DevRootScreenProps {
  /** Seed value (the current CODE_DIR from params, or '' for the first run). */
  initial: string;
  /** Save the resolved absolute path, or null to skip (keep current/default). */
  onClose: (resolved: string | null) => void;
}

export function DevRootScreen({ initial, onClose }: DevRootScreenProps) {
  const [value, setValue] = useState<string>(initial);

  const resolved = resolveDevRoot(value);
  const field: FieldSpec = {
    name: 'root',
    kind: 'path',
    label: 'Dev root — where your repos live',
    placeholder: '~/code',
    preview: resolved,
    status: devRootStatus(resolved),
  };

  useInput((input, key) => {
    if (key.escape) return onClose(null);
    if (key.return) return onClose(resolved);
    if (key.backspace || key.delete) return setValue((v) => v.slice(0, -1));
    if (input && !key.ctrl && !key.meta) setValue((v) => v + input);
  });

  return (
    <Box flexDirection="column">
      <Header title="dev root" subtitle="where your repos live" />
      <Banner
        tone="info"
        text="Used for shell auto-cd + tmux shortcuts, and the web stack's site roots if installed."
      />
      <Pane title="Dev root" tone="focus">
        <Form fields={[field]} values={{ root: value }} focusId="root" />
      </Pane>
      <Footer keys={FOOTER_KEYS} right="→ params.env (CODE_DIR)" />
    </Box>
  );
}
