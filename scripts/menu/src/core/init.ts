/**
 * init.ts — compute the picker's initial bundle selection, mirroring setup.sh:
 *   - saved ~/.config/mesh/selections.list present → re-run: start from it
 *     (dropping keys no longer in the manifest), always force required bundles.
 *   - absent → fresh install: every bundle except `default_selected: false`
 *     (required bundles always in).
 * Either way the requires_bundles closure is applied so deps are present.
 */
import { closeRequires } from './delta.js';
import { readSelections } from './selections-io.js';
import { selectionsFile } from './paths.js';
import type { BundleRef } from '../types.js';

/** Fresh-install default: required, or anything not explicitly default_selected:false. */
export function defaultSelected(refs: BundleRef[]): Set<string> {
  const sel = new Set<string>();
  for (const r of refs) {
    if (r.bundle.required || r.bundle.default_selected !== false) sel.add(r.key);
  }
  return sel;
}

/** Keys of required bundles — always selected, never deselectable. */
export function requiredKeys(refs: BundleRef[]): Set<string> {
  return new Set(refs.filter((r) => r.bundle.required).map((r) => r.key));
}

export interface InitialSelection {
  selected: Set<string>;
  /** True when a saved selections.list was the source (re-run vs fresh). */
  fromSaved: boolean;
}

/**
 * Resolve the starting selection set for the picker. `index` keys the valid
 * `topic/bundle` refs for the current platform (stale saved keys are dropped).
 */
export function initialSelection(
  refs: BundleRef[],
  index: Map<string, BundleRef>,
  selectionsPath: string = selectionsFile(),
): InitialSelection {
  const required = requiredKeys(refs);
  const saved = readSelections(selectionsPath);
  let base: Set<string>;
  let fromSaved: boolean;
  if (saved.size > 0) {
    base = new Set([...saved].filter((k) => index.has(k)));
    fromSaved = true;
  } else {
    base = defaultSelected(refs);
    fromSaved = false;
  }
  for (const k of required) base.add(k);
  return { selected: closeRequires(base, index).selected, fromSaved };
}
