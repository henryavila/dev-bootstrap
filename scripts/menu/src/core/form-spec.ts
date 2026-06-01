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
import type { ChoiceInput, FieldSpec, FieldValue, FormValues } from '@henryavila/blink-tui';
import type { Bundle, Option } from '../types.js';
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
