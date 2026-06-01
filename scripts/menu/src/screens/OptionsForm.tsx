/**
 * OptionsForm (T-305) — edit one bundle's level-3 options.
 *
 * BLINK-ONLY: the visible form is blink's <Form> (it owns the control glyphs,
 * required markers, focus fill, error lines); navigation is blink's headless
 * useFormNavigation; the app owns the keys, as blink prescribes. Header/Footer
 * are blink. Ink <Box> is layout only.
 *
 * Keys: ↑/↓ or Tab move · Space toggles a flag / selects a choice (non-text) ·
 * type / Backspace edits a text|secret field (Space is a literal char there) ·
 * Enter saves (validates) · Esc cancels.
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

const FOOTER_KEYS: HotkeyDef[] = [
  { k: 'tab', desc: 'next' },
  { k: 'space', desc: 'toggle' },
  { k: 'enter', desc: 'save' },
  { k: 'esc', desc: 'cancel' },
];

export interface OptionsFormProps {
  /** `topic/bundle` key + label for the header. */
  bundleKey: string;
  bundleLabel: string;
  fields: FieldSpec[];
  values: FormValues;
  onChange: (next: FormValues) => void;
  /** Called on save (true, validated) or cancel (false). */
  onClose: (saved: boolean) => void;
}

export function OptionsForm(props: OptionsFormProps) {
  const { fields, values } = props;
  const [errors, setErrors] = useState<Record<string, string>>({});
  const nav = useFormNavigation({ fields, values, onChange: props.onChange });

  useInput((input, key) => {
    if (key.escape) return props.onClose(false);
    if (key.upArrow) return nav.prev();
    if (key.downArrow) return nav.next();
    if (key.tab) return key.shift ? nav.prev() : nav.next();

    const stop = nav.focusStop;
    const isText = stop && (stop.kind === 'text' || stop.kind === 'secret');

    if (isText) {
      if (key.return) {
        const v = nav.commit();
        if (v.ok) props.onClose(true);
        else setErrors(v.errors);
        return;
      }
      const cur = typeof values[stop!.name] === 'string' ? (values[stop!.name] as string) : '';
      if (key.backspace || key.delete) {
        nav.setText(stop!.name, cur.slice(0, -1));
        return;
      }
      if (input && !key.ctrl && !key.meta) {
        nav.setText(stop!.name, cur + input);
      }
      return;
    }

    // non-text controls: Space toggles/selects, Enter saves
    if (input === ' ') return nav.toggle();
    if (key.return) {
      const v = nav.commit();
      if (v.ok) props.onClose(true);
      else setErrors(v.errors);
    }
  });

  return (
    <Box flexDirection="column">
      <Header title="options" subtitle={props.bundleLabel} right={props.bundleKey} />
      <Pane title="Options" tone="focus">
        <Form fields={fields} values={values} focusId={nav.focusId} errors={errors} />
      </Pane>
      <Footer keys={FOOTER_KEYS} right={`${fields.length} option${fields.length === 1 ? '' : 's'}`} />
    </Box>
  );
}
