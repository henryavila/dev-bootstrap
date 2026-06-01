/**
 * selections-io.ts (T-303) — read/write the menu state files the bash engine
 * consumes:
 *   ~/.config/mesh/selections.list — one `topic/bundle` per line (# + blank ignored)
 *   ~/.config/mesh/params.env      — KEY=value, sourced by bash (so values quote)
 *
 * Secrets are NOT written here — secret options stay unset; the owning item
 * reads secrets.env (which the engine sources) or prompts. Toggles serialise to
 * 1/0, multiselects to a space-joined list, matching the engine's silent-default
 * shapes in install-engine.sh.
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { meshConfigDir, paramsFile, selectionsFile } from './paths.js';
import type { FieldValue } from '@henryavila/blink-tui';

function ensureConfigDir(): void {
  mkdirSync(meshConfigDir(), { recursive: true });
}

function readLinesSafe(file: string): string[] | null {
  try {
    return readFileSync(file, 'utf8').split('\n');
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null;
    throw err;
  }
}

/** Selected `topic/bundle` keys from selections.list (empty set if absent). */
export function readSelections(file: string = selectionsFile()): Set<string> {
  const lines = readLinesSafe(file);
  const out = new Set<string>();
  if (!lines) return out;
  for (const raw of lines) {
    const line = raw.replace(/#.*$/, '').trim();
    if (line) out.add(line);
  }
  return out;
}

/** Write selections.list (sorted, with a provenance header). */
export function writeSelections(keys: Iterable<string>, file: string = selectionsFile()): void {
  ensureConfigDir();
  const sorted = [...new Set(keys)].sort();
  const body = ['# mesh selections — written by the setup menu (topic/bundle per line)', ...sorted].join('\n');
  writeFileSync(file, body + '\n', { mode: 0o644 });
}

const NEEDS_QUOTE = /[^A-Za-z0-9_./:@%+,=-]/;

/** Quote a params.env value if bash would mis-read it bare. */
export function quoteParam(value: string): string {
  if (value === '' || NEEDS_QUOTE.test(value)) {
    return `"${value.replace(/(["\\$`])/g, '\\$1')}"`;
  }
  return value;
}

/** Parse params.env into a KEY→value map (strips surrounding quotes). */
export function readParams(file: string = paramsFile()): Map<string, string> {
  const lines = readLinesSafe(file);
  const out = new Map<string, string>();
  if (!lines) return out;
  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let val = line.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1).replace(/\\(["\\$`])/g, '$1');
    }
    out.set(key, val);
  }
  return out;
}

/** Write params.env (sorted by key, bash-safe quoting, provenance header). */
export function writeParams(params: Map<string, string>, file: string = paramsFile()): void {
  ensureConfigDir();
  const keys = [...params.keys()].sort();
  const body = [
    '# mesh resolved options — written by the setup menu (sourced by the engine)',
    ...keys.map((k) => `${k}=${quoteParam(params.get(k) ?? '')}`),
  ].join('\n');
  writeFileSync(file, body + '\n', { mode: 0o600 });
}

/**
 * Serialise a Form field value to its params.env string, by option type:
 *   toggle → 1/0 · multiselect → space-joined · text/select/secret → as-is.
 * Returns null when the value is absent/empty (caller omits the key).
 */
export function serializeOptionValue(
  type: 'toggle' | 'multiselect' | 'select' | 'text' | 'secret',
  value: FieldValue,
): string | null {
  switch (type) {
    case 'toggle':
      return value ? '1' : '0';
    case 'multiselect': {
      const arr = Array.isArray(value) ? value : [];
      return arr.length ? arr.join(' ') : null;
    }
    default: {
      const s = typeof value === 'string' ? value : '';
      return s !== '' ? s : null;
    }
  }
}
