/**
 * form-spec.ts — turn a bundle's manifest `options` into a blink Form spec.
 *
 * Manifest option → blink FieldSpec is 1:1 on type. The side work lives here so
 * the OptionsForm component stays presentational:
 *   - `choices`     → blink ChoiceInput[]
 *   - `source: file`→ read the topic-relative file, one choice per non-comment line
 *   - `derive_from` → blink `optionsFrom` (choices come from another field)
 *   - `default_from`→ run the shell command at open, use stdout as the text default
 *   - existing params.env values pre-fill on re-run (override the schema default)
 */
import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { validateForm } from '@henryavila/blink-tui';
import type { ChoiceInput, FieldSpec, FieldValue, FormValues } from '@henryavila/blink-tui';
import type { Bundle, BundleRef, Option } from '../types.js';
import { serializeOptionValue } from './selections-io.js';

function readSourceChoices(topicDir: string, source: string): ChoiceInput[] {
  try {
    return readFileSync(path.resolve(topicDir, source), 'utf8')
      .split('\n')
      .map((l) => l.replace(/#.*$/, '').trim())
      .filter(Boolean)
      .map((v) => ({ id: v, label: v }));
  } catch {
    return [];
  }
}

function runDefaultFrom(cmd: string): string {
  try {
    return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

function choicesOf(opt: Option, topicDir: string): ChoiceInput[] | undefined {
  if (opt.choices?.length) return opt.choices.map((c) => ({ id: c.value, label: c.label }));
  if (opt.source) return readSourceChoices(topicDir, opt.source);
  return undefined;
}

/** Choices flagged `default: true` in the manifest (multiselect/select pre-selection). */
function defaultChoiceValues(opt: Option): string[] {
  return (opt.choices ?? []).filter((c) => c.default).map((c) => c.value);
}

/** Initial value for one option: existing params.env wins, else the schema default. */
function initialValue(opt: Option, existing: Map<string, string>): FieldValue {
  const fromEnv = existing.get(opt.env);
  switch (opt.type) {
    case 'toggle':
      if (fromEnv !== undefined) return /^(1|true|yes|on)$/i.test(fromEnv);
      return opt.default === true;
    case 'multiselect': {
      if (fromEnv !== undefined) return fromEnv.split(/\s+/).filter(Boolean);
      if (Array.isArray(opt.default)) return opt.default as string[];
      const dc = defaultChoiceValues(opt);
      return dc.length ? dc : [];
    }
    case 'select': {
      if (fromEnv !== undefined) return fromEnv;
      if (typeof opt.default === 'string') return opt.default;
      const dc = defaultChoiceValues(opt);
      return dc[0] ?? '';
    }
    case 'text': {
      if (fromEnv !== undefined) return fromEnv;
      if (opt.default_from) {
        const v = runDefaultFrom(opt.default_from);
        if (v) return v;
      }
      return typeof opt.default === 'string' ? opt.default : '';
    }
    case 'secret':
      return ''; // never pre-filled
  }
}

export interface BundleFormSpec {
  fields: FieldSpec[];
  values: FormValues;
  /** option.name → its env var, for serialising values back to params.env. */
  envByName: Map<string, { env: string; type: Option['type'] }>;
}

/** Build the blink Form spec + initial values for a bundle's options. */
export function buildFormSpec(
  bundle: Bundle,
  topicDir: string,
  existing: Map<string, string> = new Map(),
): BundleFormSpec {
  const fields: FieldSpec[] = [];
  const values: FormValues = {};
  const envByName = new Map<string, { env: string; type: Option['type'] }>();
  for (const opt of bundle.options ?? []) {
    envByName.set(opt.name, { env: opt.env, type: opt.type });
    const field: FieldSpec = { name: opt.name, kind: opt.type, label: opt.label, required: opt.required };
    if (opt.type === 'select' || opt.type === 'multiselect') {
      if (opt.derive_from) field.optionsFrom = opt.derive_from;
      else field.choices = choicesOf(opt, topicDir);
    }
    if (opt.type === 'multiselect' && typeof opt.required_min === 'number') {
      field.min = opt.required_min;
    }
    fields.push(field);
    values[opt.name] = initialValue(opt, existing);
  }
  return { fields, values, envByName };
}

/**
 * Fold a bundle's resolved form values into a params map (mutates + returns it).
 * Each option writes its env var; empty/absent values delete the key so a
 * re-run that clears a field doesn't leave a stale param.
 */
export function applyFormValues(
  spec: BundleFormSpec,
  values: FormValues,
  params: Map<string, string>,
): Map<string, string> {
  for (const [name, { env, type }] of spec.envByName) {
    const serial = serializeOptionValue(type, values[name]);
    if (serial === null) params.delete(env);
    else params.set(env, serial);
  }
  return params;
}

/**
 * Pre-resolve every selected bundle's option defaults (static + default_from)
 * into `params`, without overwriting values the user already set. Run on
 * confirm so an option with a default lands in params.env even when the user
 * never opened that bundle's options form — otherwise the engine (interactive
 * mode = "menu owns prompting") never sees it. Mutates + returns `params`.
 *
 * buildFormSpec already folds existing params over the defaults, so re-applying
 * its resolved `values` is idempotent for already-set keys and only fills the
 * gaps. (e.g. personal/repo's default_from = the existing identity origin → its
 * MESH_IDENTITY_REPO is persisted without the user touching the form.)
 */
export function resolveSelectedDefaults(
  refs: BundleRef[],
  params: Map<string, string>,
): Map<string, string> {
  for (const ref of refs) {
    if (!ref.bundle.options?.length) continue;
    const spec = buildFormSpec(ref.bundle, ref.topic.dir, params);
    applyFormValues(spec, spec.values, params);
  }
  return params;
}

/**
 * A field the OptionsForm can actually collect a value for. A select/multiselect
 * with no resolvable choices (e.g. an empty `source:` file, or no `choices`/
 * `derive_from`) is uncollectable — it must not gate, or the user would be
 * trapped in a form they cannot satisfy. text/toggle are always collectable;
 * secret is filtered out earlier (collected via secrets.env, not the menu).
 */
function isCollectable(f: FieldSpec): boolean {
  if (f.kind === 'select' || f.kind === 'multiselect') {
    return (f.choices?.length ?? 0) > 0 || f.optionsFrom != null;
  }
  return true;
}

/**
 * Of the given (selected) bundles, the ones that still have an UNFILLED required
 * option — the menu's apply-time gate (Option A). A bundle gates only if it
 * declares a non-secret option that is `required` or carries a `required_min`
 * (matching exactly what the OptionsForm's save-time validateForm enforces); that
 * cheap manifest check runs BEFORE the possibly-shelling-out buildFormSpec, so a
 * bundle with only optional/default_from options (e.g. git/config, personal) pays
 * nothing. Each gating bundle is then resolved with buildFormSpec (existing
 * params > default_from > static default) and blink's validateForm flags an empty
 * required field / unmet min.
 *
 * Exemptions — the menu can't collect these, so they never gate (apply.sh or the
 * secrets layer surface them instead): `secret`-type options, and select/
 * multiselect options with no resolvable choices. Read-only on `params` (never
 * mutates it). Offenders are returned in input order so the caller can route the
 * user to the first one's options form.
 */
export function incompleteRequired(
  refs: BundleRef[],
  params: Map<string, string> = new Map(),
): BundleRef[] {
  const out: BundleRef[] = [];
  for (const ref of refs) {
    const gating = (ref.bundle.options ?? []).filter(
      (o) => o.type !== 'secret' && (o.required || typeof o.required_min === 'number'),
    );
    if (gating.length === 0) continue;
    const gatingNames = new Set(gating.map((o) => o.name));
    const spec = buildFormSpec(ref.bundle, ref.topic.dir, params);
    const fields = spec.fields.filter((f) => gatingNames.has(f.name) && isCollectable(f));
    if (fields.length === 0) continue;
    if (!validateForm(fields, spec.values).ok) out.push(ref);
  }
  return out;
}
