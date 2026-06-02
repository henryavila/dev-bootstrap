/**
 * wizard.tsx — the App component + screen router for the mesh setup wizard.
 *
 * The bootstrap (render + main) lives in app.tsx (the index.js entry); this
 * module is side-effect-free and exports <App/> so it is unit-testable.
 *
 * The App owns shared state (selection set, resolved params); each screen owns
 * its own keys (blink's headless model). Only one screen mounts at a time, so
 * exactly one useInput is live. On confirm it writes
 * ~/.config/mesh/{selections.list,params.env} and signals exit 0; cancel/quit
 * signals exit 1 so the caller falls back to the saved/default selection.
 *
 * BLINK-ONLY (feedback_mesh_ink_app_blink_only): every visible element is a
 * blink component; Ink Box/Text are layout + the unavoidable plain-text leaves.
 */
import { useMemo, useState } from 'react';
import { Box, useApp, useInput } from 'ink';
import { Dialog, useGlyph, type FormValues, type DialogAction } from '@henryavila/blink-tui';
import { detectPlatform } from './core/platform.js';
import {
  readAllManifests,
  filterByPlatform,
  flattenBundles,
  indexByKey,
} from './core/manifest-reader.js';
import { scanAll } from './core/scanner.js';
import { initialSelection, requiredKeys } from './core/init.js';
import { closeRequires, dependentsOf, computeDelta } from './core/delta.js';
import { writeSelections, writeParams, readParams } from './core/selections-io.js';
import { buildFormSpec, applyFormValues, resolveSelectedDefaults, type BundleFormSpec } from './core/form-spec.js';
import { TopicPicker } from './screens/TopicPicker.js';
import { OptionsForm } from './screens/OptionsForm.js';
import { SummaryConfirm } from './screens/SummaryConfirm.js';
import { UpdatesScreen, UPDATE_ENV, updateValuesFromParams } from './screens/UpdatesScreen.js';
import type { BundleRef } from './types.js';

type Screen = 'picker' | 'options' | 'summary' | 'updates' | 'help' | 'confirmRemove';

interface Editing {
  ref: BundleRef;
  spec: BundleFormSpec;
  values: FormValues;
}

interface AppProps {
  dryRun: boolean;
  onExit: (code: number) => void;
}

export function App({ dryRun, onExit }: AppProps) {
  const ink = useApp();

  // ── boot (computed once) ──
  const platform = useMemo(() => detectPlatform(), []);
  const topics = useMemo(() => filterByPlatform(readAllManifests(), platform), [platform]);
  const refs = useMemo(() => flattenBundles(topics), [topics]);
  const index = useMemo(() => indexByKey(refs), [refs]);
  const scan = useMemo(() => scanAll(refs, platform), [refs, platform]);
  const required = useMemo(() => requiredKeys(refs), [refs]);
  const init = useMemo(() => initialSelection(refs, index), [refs, index]);
  // Apply baseline: saved selection on re-run, empty on a fresh install (so the
  // summary shows the defaults as "install", not "keep").
  const prevSelection = useMemo(
    () => (init.fromSaved ? new Set(init.selected) : new Set<string>()),
    [init],
  );

  const [screen, setScreen] = useState<Screen>('picker');
  const [selected, setSelected] = useState<Set<string>>(() => init.selected);
  const [params, setParams] = useState<Map<string, string>>(() => readParams());
  const [banner, setBanner] = useState<string | null>(null);
  const [editing, setEditing] = useState<Editing | null>(null);
  const [updateValues, setUpdateValues] = useState<FormValues>({});
  const [confirm, setConfirm] = useState<{ key: string; deps: string[] } | null>(null);

  const finish = (code: number) => {
    if (code === 0 && !dryRun) {
      // Persist resolved option defaults for every selected bundle, not just the
      // ones whose options form was opened — otherwise a default_from value
      // (e.g. personal/repo → MESH_IDENTITY_REPO) never reaches params.env and
      // the engine fails on it. Copy params so the resolve doesn't mutate state.
      const selectedRefs = [...selected]
        .map((k) => index.get(k))
        .filter((r): r is BundleRef => r !== undefined);
      const resolved = resolveSelectedDefaults(selectedRefs, new Map(params));
      writeSelections([...selected]);
      writeParams(resolved);
    }
    onExit(code);
    ink.exit();
  };

  // ── selection handlers (closure + auto-select banner + dependent guard) ──
  const toggle = (key: string) => {
    if (required.has(key)) return;
    if (selected.has(key)) {
      const deps = dependentsOf(key, selected, index);
      if (deps.length) {
        setConfirm({ key, deps });
        setScreen('confirmRemove');
        return;
      }
      const next = new Set(selected);
      next.delete(key);
      setSelected(next);
      setBanner(null);
    } else {
      const { selected: closed, added } = closeRequires([...selected, key], index);
      setSelected(closed);
      setBanner(added.length ? `Auto-selected: ${added.join(', ')}` : null);
    }
  };

  const removeWithDependents = () => {
    if (!confirm) return setScreen('picker');
    const next = new Set(selected);
    next.delete(confirm.key);
    for (const d of confirm.deps) next.delete(d);
    setSelected(next);
    setBanner(`Removed ${confirm.key} + ${confirm.deps.length} dependent(s)`);
    setConfirm(null);
    setScreen('picker');
  };

  const selectAll = () => {
    setSelected(new Set(refs.map((r) => r.key)));
    setBanner(null);
  };
  const selectNone = () => {
    setSelected(closeRequires(required, index).selected);
    setBanner(null);
  };

  const editOptions = (ref: BundleRef) => {
    const spec = buildFormSpec(ref.bundle, ref.topic.dir, params);
    setEditing({ ref, spec, values: spec.values });
    setScreen('options');
  };
  const closeOptions = (saved: boolean) => {
    if (saved && editing) {
      const next = new Map(params);
      applyFormValues(editing.spec, editing.values, next);
      setParams(next);
      setBanner(`Saved options for ${editing.ref.key}`);
    }
    setEditing(null);
    setScreen('picker');
  };

  const openUpdates = () => {
    setUpdateValues(updateValuesFromParams(params));
    setScreen('updates');
  };
  const closeUpdates = (saved: boolean) => {
    if (saved) {
      const next = new Map(params);
      for (const [name, env] of Object.entries(UPDATE_ENV)) {
        next.set(env, updateValues[name] ? '1' : '0');
      }
      setParams(next);
      setBanner('Update categories saved');
    }
    setScreen('picker');
  };

  // ── screens ──
  if (screen === 'options' && editing) {
    return (
      <OptionsForm
        bundleKey={editing.ref.key}
        bundleLabel={editing.ref.bundle.label}
        fields={editing.spec.fields}
        values={editing.values}
        onChange={(v) => setEditing((e) => (e ? { ...e, values: v } : e))}
        onClose={closeOptions}
      />
    );
  }
  if (screen === 'summary') {
    return (
      <SummaryConfirm
        delta={computeDelta(prevSelection, selected)}
        index={index}
        applyLabel={dryRun ? 'dry-run (nothing written)' : 'writes selections.list + params.env'}
        onConfirm={() => finish(0)}
        onBack={() => setScreen('picker')}
        onQuit={() => finish(1)}
      />
    );
  }
  if (screen === 'updates') {
    return (
      <UpdatesScreen
        values={updateValues}
        onChange={setUpdateValues}
        onClose={closeUpdates}
      />
    );
  }
  if (screen === 'help') {
    return <HelpDialog onClose={() => setScreen('picker')} />;
  }
  if (screen === 'confirmRemove' && confirm) {
    return (
      <RemoveDialog
        target={confirm.key}
        deps={confirm.deps}
        onRemoveAll={removeWithDependents}
        onKeep={() => {
          setConfirm(null);
          setScreen('picker');
        }}
      />
    );
  }

  return (
    <TopicPicker
      topics={topics}
      platform={platform}
      selected={selected}
      required={required}
      scan={scan}
      banner={banner}
      onToggle={toggle}
      onSelectAll={selectAll}
      onSelectNone={selectNone}
      onEditOptions={editOptions}
      onContinue={() => setScreen('summary')}
      onUpdates={openUpdates}
      onHelp={() => setScreen('help')}
      onQuit={() => finish(1)}
    />
  );
}

const HELP_LINES = [
  'Choose the bundles to install, then press  c  to apply.',
  'Move      ↑ ↓ / k j     within a pane',
  '          Tab / ← →     switch topics ⇄ bundles',
  'Select    Space         add / remove a bundle',
  '          a / n         select all / none',
  'Options   Enter         edit a bundle’s options',
  'Updates   u             what `mesh update` upgrades',
  'Finish    c  apply       ·    q  cancel',
];

function HelpDialog({ onClose }: { onClose: () => void }) {
  useInput(() => onClose());
  // Legend built from the active icon set (not hardcoded unicode) so the glyphs
  // shown here match exactly what the TopicPicker rows + quick legend render.
  // Mirrors blink's selectionIntents (checkbox*) + stateIntents (check/half/cross).
  const g = useGlyph();
  const lines = [
    ...HELP_LINES,
    '',
    `Status    ${g('checkboxOn')} selected   ${g('checkboxOff')} off   ${g('checkboxLock')} required`,
    `          ${g('check')} installed   ${g('half')} partial   ${g('cross')} not installed`,
  ];
  return (
    <Box flexDirection="column">
      <Dialog title="how to use" tone="default" lines={lines} actions={[{ key: 'any', label: 'close' }]} width={62} />
    </Box>
  );
}

function RemoveDialog({
  target,
  deps,
  onRemoveAll,
  onKeep,
}: {
  target: string;
  deps: string[];
  onRemoveAll: () => void;
  onKeep: () => void;
}) {
  useInput((input, key) => {
    if (input === 'y') return onRemoveAll();
    if (input === 'k' || key.escape) return onKeep();
  });
  const actions: DialogAction[] = [
    { key: 'y', label: 'remove all', primary: true },
    { key: 'k', label: 'keep' },
  ];
  const lines = [
    `${target} is required by:`,
    ...deps.map((d) => `  • ${d}`),
    '',
    'Remove it and the dependents above, or keep them?',
  ];
  return (
    <Box flexDirection="column">
      <Dialog title="remove dependency" tone="error" lines={lines} actions={actions} width={64} />
    </Box>
  );
}
