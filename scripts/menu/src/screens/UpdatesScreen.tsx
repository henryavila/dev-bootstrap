/**
 * UpdatesScreen (T-600) — toggle the three opt-in version-aware update
 * categories. Writes MESH_UPDATE_AGENT_CLIS / MESH_UPDATE_RUNTIMES_DBS /
 * MESH_UPDATE_CLI_TOOLS to params.env (1/0). All default OFF; `mesh update` is a
 * no-op unless a category is on (engine T-600 motor, commits d3f6135/cf066b1).
 *
 * BLINK-ONLY: blink <Form> + useFormNavigation; app owns keys. Layout via Box.
 */
import { Box, useInput } from 'ink';
import {
  Header,
  Footer,
  Pane,
  Form,
  Banner,
  useFormNavigation,
  type FieldSpec,
  type FormValues,
  type HotkeyDef,
} from '@henryavila/blink-tui';

/** Field name → params.env env var. */
export const UPDATE_ENV: Record<string, string> = {
  'agent-clis': 'MESH_UPDATE_AGENT_CLIS',
  'runtimes-dbs': 'MESH_UPDATE_RUNTIMES_DBS',
  'cli-tools': 'MESH_UPDATE_CLI_TOOLS',
};

const UPDATE_FIELDS: FieldSpec[] = [
  { name: 'agent-clis', kind: 'toggle', label: 'Agent CLIs — Claude/Codex/Gemini, mdprobe, atomic-skills…' },
  { name: 'runtimes-dbs', kind: 'toggle', label: 'Runtimes & databases — Node/PHP/Python, MySQL/Postgres/Redis' },
  { name: 'cli-tools', kind: 'toggle', label: 'CLI tools — everything else (brew/apt/cargo CLIs)' },
];

const FOOTER_KEYS: HotkeyDef[] = [
  { k: 'space', desc: 'toggle' },
  { k: 'enter', desc: 'save' },
  { k: 'esc', desc: 'back' },
];

/** Build initial toggle values from params.env (1/true → on). */
export function updateValuesFromParams(params: Map<string, string>): FormValues {
  const v: FormValues = {};
  for (const [name, env] of Object.entries(UPDATE_ENV)) {
    v[name] = /^(1|true|yes|on)$/i.test(params.get(env) ?? '');
  }
  return v;
}

export interface UpdatesScreenProps {
  values: FormValues;
  onChange: (next: FormValues) => void;
  onClose: (saved: boolean) => void;
}

export function UpdatesScreen(props: UpdatesScreenProps) {
  const nav = useFormNavigation({ fields: UPDATE_FIELDS, values: props.values, onChange: props.onChange });

  useInput((input, key) => {
    if (key.escape) return props.onClose(false);
    if (key.upArrow) return nav.prev();
    if (key.downArrow || key.tab) return nav.next();
    if (input === ' ') return nav.toggle();
    if (key.return) return props.onClose(true);
  });

  const on = Object.keys(UPDATE_ENV).filter((n) => props.values[n]).length;

  return (
    <Box flexDirection="column">
      <Header title="updates" subtitle="version-aware, opt-in" right={`${on}/3 on`} />
      <Pane title="What should `mesh update` upgrade?" tone="focus">
        <Form fields={UPDATE_FIELDS} values={props.values} focusId={nav.focusId} />
      </Pane>
      <Banner tone="info" text="All off by default — only enabled categories upgrade on `mesh update`." />
      <Footer keys={FOOTER_KEYS} right="→ params.env" />
    </Box>
  );
}
