/**
 * PromptScreen — a SINGLE blink-tui field, so install-time bash prompts (the
 * git-crypt key, init name/email, confirmations) use the SAME engine as the
 * menu's CODE_DIR / identity onboarding instead of a bare `read`. Driven from
 * bash via `node index.js prompt --type … --label … --out <file>` (see
 * scripts/lib/log.sh); the chosen value is written to --out and the process
 * exits 0, or exits 130 on Esc (cancel) so the caller can fall back.
 *
 * BLINK-ONLY: blink's <Form> (one field) + Header/Footer/Pane own the visuals;
 * navigation is blink's headless useFormNavigation; the app owns the keys, as
 * OptionsForm/DevRootScreen do. Ink <Box> is layout only.
 *
 * Keys (text/secret): type / Backspace edit · Enter accept (empty → default) ·
 * Esc cancel.  Keys (confirm): y/n choose · Space toggle · Enter accept · Esc.
 */
import { useState } from 'react';
import { Box, useInput } from 'ink';
import {
  Header,
  Footer,
  Pane,
  Form,
  useFormNavigation,
  type FieldSpec,
  type FormValues,
  type HotkeyDef,
} from '@henryavila/blink-tui';

export type PromptType = 'text' | 'secret' | 'confirm' | 'select';
/** Every prompt kind bash can request — PromptScreen handles the field kinds;
 *  `pause` is an acknowledge handled by PauseScreen (a Dialog, not a field). */
export type PromptArgType = PromptType | 'pause';

/** The single field's name — the value contract between this screen and bash. */
const NAME = 'value';

export interface Choice {
  id: string;
  label: string;
}

export interface PromptArgs {
  type: PromptArgType;
  label: string;
  default: string;
  out: string;
  choices: Choice[];
}

/** Parse `--choices` — newline-separated `id=label` lines (split on the FIRST
 *  `=`, so labels may contain `=`). Empty lines dropped. Pure. */
export function parseChoices(raw: string | undefined): Choice[] {
  if (!raw) return [];
  return raw
    .split('\n')
    .map((line) => line.trimEnd())
    .filter((line) => line.length > 0)
    .map((line) => {
      const eq = line.indexOf('=');
      return eq < 0 ? { id: line, label: line } : { id: line.slice(0, eq), label: line.slice(eq + 1) };
    });
}

/** Parse the `prompt` argv (everything AFTER the `prompt` subcommand). Pure.
 *  Returns null on a missing/invalid --type, a missing --out, or a `select` with
 *  no choices (the caller then exits non-zero so bash falls back to its read). */
export function parsePromptArgs(argv: string[]): PromptArgs | null {
  const get = (flag: string): string | undefined => {
    const i = argv.indexOf(flag);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : undefined;
  };
  const type = get('--type');
  const out = get('--out');
  const valid =
    type === 'text' || type === 'secret' || type === 'confirm' || type === 'select' || type === 'pause';
  if (!valid || !out) return null;
  const choices = parseChoices(get('--choices'));
  if (type === 'select' && choices.length === 0) return null;
  return {
    type: type as PromptArgType,
    label: get('--label') ?? '',
    default: get('--default') ?? '',
    out,
    choices,
  };
}

/** Whether a `--default` string means "yes" for a confirm. */
export function isYes(s: string): boolean {
  return s === 'y' || s === 'Y' || s === 'yes' || s === 'true' || s === '1';
}

export interface PromptScreenProps {
  type: PromptType;
  label: string;
  defaultValue?: string;
  /** Choices for `kind: 'select'` (ignored otherwise). */
  choices?: Choice[];
  /** Called with the value (text/secret string, 'y'/'n' for confirm, or the
   *  chosen id for select) on accept, or null on cancel (Esc). */
  onDone: (value: string | null) => void;
}

export function PromptScreen({
  type,
  label,
  defaultValue = '',
  choices = [],
  onDone,
}: PromptScreenProps) {
  const isConfirm = type === 'confirm';
  const isSelect = type === 'select';
  const fields: FieldSpec[] = [
    isConfirm
      ? { name: NAME, label, kind: 'toggle' }
      : isSelect
        ? { name: NAME, label, kind: 'select', choices }
        : {
            name: NAME,
            label,
            kind: type === 'secret' ? 'secret' : 'text',
            placeholder: defaultValue || undefined,
          },
  ];
  const [values, setValues] = useState<FormValues>(
    isConfirm
      ? { [NAME]: isYes(defaultValue) }
      : isSelect
        ? { [NAME]: defaultValue } // pre-select the default choice
        : { [NAME]: '' },
  );
  const nav = useFormNavigation({ fields, values, onChange: setValues });

  useInput((input, key) => {
    if (key.escape) return onDone(null);

    // text / secret — type to edit, Enter accepts (empty → default)
    if (!isConfirm && !isSelect) {
      const cur = typeof values[NAME] === 'string' ? (values[NAME] as string) : '';
      if (key.return) return onDone(cur !== '' ? cur : defaultValue);
      if (key.backspace || key.delete) return nav.setText(NAME, cur.slice(0, -1));
      if (input && !key.ctrl && !key.meta) return nav.setText(NAME, cur + input);
      return;
    }

    // select — ↑/↓ move, Space selects the focused choice, Enter accepts current
    if (isSelect) {
      if (key.upArrow) return nav.prev();
      if (key.downArrow) return nav.next();
      if (key.tab) return key.shift ? nav.prev() : nav.next();
      if (input === ' ') return nav.toggle();
      if (key.return) {
        const cur = typeof values[NAME] === 'string' ? (values[NAME] as string) : '';
        return onDone(cur !== '' ? cur : defaultValue);
      }
      return;
    }

    // confirm (toggle) — y/n decide immediately, Space flips, Enter takes current
    if (input === ' ') return nav.toggle();
    if (input === 'y' || input === 'Y') {
      setValues({ [NAME]: true });
      return onDone('y');
    }
    if (input === 'n' || input === 'N') {
      setValues({ [NAME]: false });
      return onDone('n');
    }
    if (key.return) return onDone(values[NAME] ? 'y' : 'n');
  });

  const footer: HotkeyDef[] = isConfirm
    ? [
        { k: 'y/n', desc: 'choose' },
        { k: 'enter', desc: 'ok' },
        { k: 'esc', desc: 'cancel' },
      ]
    : isSelect
      ? [
          { k: '↑/↓', desc: 'move' },
          { k: 'space', desc: 'select' },
          { k: 'enter', desc: 'ok' },
          { k: 'esc', desc: 'cancel' },
        ]
      : [
          { k: 'enter', desc: 'ok' },
          { k: 'esc', desc: 'cancel' },
        ];

  return (
    <Box flexDirection="column">
      <Header title="mesh" subtitle={type === 'secret' ? 'secret' : 'input'} />
      <Pane title={label} tone="focus">
        <Form fields={fields} values={values} focusId={nav.focusId} errors={{}} />
      </Pane>
      <Footer keys={footer} />
    </Box>
  );
}
