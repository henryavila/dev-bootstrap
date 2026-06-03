/**
 * IdentityOnboarding — the dedicated create-or-adopt flow for the personal
 * identity repo, the one bundle whose value can't be expressed as a flat option
 * form (options have no `when:`, so a conditional "URL xor create-from-template"
 * can't gate fields). It ports the apply.sh `_prompt_identity_repo` /dev/tty
 * onboarding into the menu so the interactive run collects it up-front instead of
 * the engine falling back at apply time.
 *
 * It writes the same env contract apply.sh + scripts/lib/identity-repo.sh read:
 *   adopt  → MESH_IDENTITY_REPO=<url|owner/name>  (and clears any stale create-*)
 *   create → CREATE_IDENTITY_FROM_TEMPLATE=1 + MESH_IDENTITY_TEMPLATE_REPO +
 *            MESH_IDENTITY_NEW_REPO_{OWNER,NAME,PRIVATE} + MESH_IDENTITY_REPO=owner/name
 *
 * BLINK-ONLY: blink List (mode pick) + Form (the two field sets) + Header/Footer/
 * Banner; navigation via blink's headless hooks; the app owns the keys. Ink <Box>
 * is layout only.
 *
 * Keys: mode — ↑/↓ move · Enter pick · Esc cancel. form — ↑/↓ or Tab move ·
 * type/Backspace edit a text field · Space toggle `private` · Enter save
 * (validates) · Esc back to the mode pick.
 */
import { useState } from 'react';
import { Box, useInput } from 'ink';
import {
  Header,
  Footer,
  Pane,
  Form,
  Banner,
  List,
  useFormNavigation,
  useListNavigation,
  type FieldSpec,
  type FormValues,
  type HotkeyDef,
  type ListRowData,
} from '@henryavila/blink-tui';

/** The env vars this screen resolves — the identity-repo contract (apply.sh +
 *  scripts/lib/identity-repo.sh). MESH_IDENTITY_REPO is also the option env the
 *  wizard uses to recognise the identity bundle. */
export const IDENTITY_ENV = {
  repo: 'MESH_IDENTITY_REPO',
  create: 'CREATE_IDENTITY_FROM_TEMPLATE',
  template: 'MESH_IDENTITY_TEMPLATE_REPO',
  owner: 'MESH_IDENTITY_NEW_REPO_OWNER',
  name: 'MESH_IDENTITY_NEW_REPO_NAME',
  private: 'MESH_IDENTITY_NEW_REPO_PRIVATE',
} as const;

const ALL_IDENTITY_KEYS = Object.values(IDENTITY_ENV);

/** params.env delta: env var → value, or null to delete the key. */
export type IdentityDelta = Record<string, string | null>;
export interface IdentityResult {
  params: IdentityDelta;
}

/** Adopt an existing repo: set MESH_IDENTITY_REPO, clear any stale create-* keys
 *  (so a previous create answer doesn't linger and re-trigger gh repo create). */
export function adoptDelta(repo: string): IdentityDelta {
  const d: IdentityDelta = {};
  for (const k of ALL_IDENTITY_KEYS) d[k] = null;
  d[IDENTITY_ENV.repo] = repo.trim();
  return d;
}

/** Create from a template: the full create-* env set + a placeholder
 *  MESH_IDENTITY_REPO=owner/name (so the required-option gate is satisfied and
 *  apply.sh's guard sees a value; identity-repo.sh runs `gh repo create`). */
export function createDelta(i: {
  template: string;
  owner: string;
  name: string;
  private: boolean;
}): IdentityDelta {
  const owner = i.owner.trim();
  const name = i.name.trim();
  return {
    [IDENTITY_ENV.create]: '1',
    [IDENTITY_ENV.template]: i.template.trim(),
    [IDENTITY_ENV.owner]: owner,
    [IDENTITY_ENV.name]: name,
    [IDENTITY_ENV.private]: i.private ? '1' : '0',
    [IDENTITY_ENV.repo]: `${owner}/${name}`,
  };
}

const ADOPT_FIELDS: FieldSpec[] = [
  { name: 'repo', kind: 'text', label: 'Existing repo (URL or owner/name)', required: true },
];
const CREATE_FIELDS: FieldSpec[] = [
  { name: 'template', kind: 'text', label: 'Template repo (owner/name)', required: true },
  { name: 'owner', kind: 'text', label: 'New repo owner', required: true },
  { name: 'name', kind: 'text', label: 'New repo name', required: true },
  { name: 'private', kind: 'toggle', label: 'Private repo' },
];

const MODE_ROWS: ListRowData[] = [
  { id: 'adopt', label: 'Adopt an existing repo  (URL or owner/name)' },
  { id: 'create', label: 'Create a new repo from a template' },
];

const MODE_KEYS: HotkeyDef[] = [
  { k: '↑↓', desc: 'move' },
  { k: 'enter', desc: 'pick' },
  { k: 'esc', desc: 'cancel' },
];
const FORM_KEYS: HotkeyDef[] = [
  { k: 'tab', desc: 'next' },
  { k: 'space', desc: 'toggle' },
  { k: 'enter', desc: 'save' },
  { k: 'esc', desc: 'back' },
];

type Step = 'mode' | 'adopt' | 'create';

export interface IdentityOnboardingProps {
  /** Current params.env, used to seed the fields on (re)open. */
  initial: Map<string, string>;
  /** Reason banner when opened by the required-option gate. */
  notice?: string;
  /** Default owner for the create flow (the wizard pre-runs `gh api user`). */
  defaultOwner?: string;
  /** Called with the resolved delta on save, or null on cancel. */
  onClose: (result: IdentityResult | null) => void;
}

export function IdentityOnboarding(props: IdentityOnboardingProps) {
  const { initial } = props;
  const seededCreate = initial.get(IDENTITY_ENV.create) === '1';

  const [step, setStep] = useState<Step>(seededCreate ? 'create' : 'mode');
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [adoptVals, setAdoptVals] = useState<FormValues>({
    repo: seededCreate ? '' : initial.get(IDENTITY_ENV.repo) ?? '',
  });
  const [createVals, setCreateVals] = useState<FormValues>({
    template: initial.get(IDENTITY_ENV.template) || 'henryavila/dotfiles-template',
    owner: initial.get(IDENTITY_ENV.owner) || props.defaultOwner || '',
    name: initial.get(IDENTITY_ENV.name) || 'mesh-identity',
    private: (initial.get(IDENTITY_ENV.private) ?? '1') !== '0',
  });

  // All three hooks run every render (no conditional hooks); input is routed to
  // the active one by `step`.
  const modeNav = useListNavigation({ ids: MODE_ROWS.map((r) => r.id) });
  const adoptNav = useFormNavigation({ fields: ADOPT_FIELDS, values: adoptVals, onChange: setAdoptVals });
  const createNav = useFormNavigation({ fields: CREATE_FIELDS, values: createVals, onChange: setCreateVals });

  const commitStep = () => {
    if (step === 'adopt') {
      const v = adoptNav.commit();
      if (!v.ok) return setErrors(v.errors);
      props.onClose({ params: adoptDelta(String(adoptVals.repo ?? '')) });
    } else {
      const v = createNav.commit();
      if (!v.ok) return setErrors(v.errors);
      props.onClose({
        params: createDelta({
          template: String(createVals.template ?? ''),
          owner: String(createVals.owner ?? ''),
          name: String(createVals.name ?? ''),
          private: createVals.private === true,
        }),
      });
    }
  };

  useInput((input, key) => {
    if (step === 'mode') {
      if (key.escape) return props.onClose(null);
      if (key.upArrow || input === 'k') return modeNav.focusPrev();
      if (key.downArrow || input === 'j') return modeNav.focusNext();
      if (key.return) {
        setErrors({});
        const next = modeNav.focusedId === 'create' ? 'create' : 'adopt';
        // Re-enter a form at its first field (nav focus index persists across
        // step switches since all hooks stay mounted for the screen's lifetime).
        if (next === 'create') createNav.focusField('template');
        else adoptNav.focusField('repo');
        setStep(next);
      }
      return;
    }

    // adopt / create form
    const nav = step === 'adopt' ? adoptNav : createNav;
    const vals = step === 'adopt' ? adoptVals : createVals;
    if (key.escape) {
      setErrors({});
      setStep('mode');
      return;
    }
    if (key.upArrow) return nav.prev();
    if (key.downArrow) return nav.next();
    if (key.tab) return key.shift ? nav.prev() : nav.next();

    const stop = nav.focusStop;
    const isText = stop && (stop.kind === 'text' || stop.kind === 'secret');
    if (isText) {
      if (key.return) return commitStep();
      const cur = typeof vals[stop!.name] === 'string' ? (vals[stop!.name] as string) : '';
      if (key.backspace || key.delete) return nav.setText(stop!.name, cur.slice(0, -1));
      if (input && !key.ctrl && !key.meta) nav.setText(stop!.name, cur + input);
      return;
    }
    // non-text (the private toggle): Space toggles, Enter saves
    if (input === ' ') return nav.toggle();
    if (key.return) return commitStep();
  });

  if (step === 'mode') {
    return (
      <Box flexDirection="column">
        <Header title="identity" subtitle="your private mesh-identity repo" />
        {props.notice ? <Banner tone="warn" text={props.notice} /> : null}
        <Pane title="Do you already have a mesh-identity repo?" tone="focus">
          <List rows={MODE_ROWS} focusedId={modeNav.focusedId} height={MODE_ROWS.length} />
        </Pane>
        <Footer keys={MODE_KEYS} right="→ params.env" />
      </Box>
    );
  }

  const fields = step === 'adopt' ? ADOPT_FIELDS : CREATE_FIELDS;
  const values = step === 'adopt' ? adoptVals : createVals;
  const nav = step === 'adopt' ? adoptNav : createNav;
  const subtitle = step === 'adopt' ? 'adopt an existing repo' : 'create from a template';
  return (
    <Box flexDirection="column">
      <Header title="identity" subtitle={subtitle} />
      {props.notice ? <Banner tone="warn" text={props.notice} /> : null}
      <Pane title="Options" tone="focus">
        <Form fields={fields} values={values} focusId={nav.focusId} errors={errors} />
      </Pane>
      <Footer keys={FORM_KEYS} right={`${fields.length} field${fields.length === 1 ? '' : 's'}`} />
    </Box>
  );
}
