/**
 * delta.ts — pure selection logic shared by the picker and the summary:
 *   - requires_bundles transitive closure (auto-select deps, spec D-6)
 *   - dependent lookup (who still needs a bundle the user is removing)
 *   - install/keep/remove delta between the saved and the new selection
 *
 * Keys are canonical `topic/bundle` strings. The validator guarantees every
 * requires_bundles target resolves and the dep graph is acyclic; we still guard
 * (visited set + missing-target skip) so a hand-edited manifest can't hang or
 * crash the menu.
 */
import type { BundleRef } from '../types.js';

/** requires_bundles for a key, filtered to targets that exist in the index. */
function depsOf(key: string, index: Map<string, BundleRef>): string[] {
  const ref = index.get(key);
  if (!ref) return [];
  return (ref.bundle.requires_bundles ?? []).filter((d) => index.has(d));
}

export interface ClosureResult {
  /** Selected set with all transitive deps added. */
  selected: Set<string>;
  /** Keys that were auto-added by the closure (not in the input set). */
  added: string[];
}

/**
 * Add the transitive requires_bundles closure of `selected`. Returns a new set;
 * `added` lists what the closure pulled in (for the auto-select banner).
 */
export function closeRequires(
  selected: Iterable<string>,
  index: Map<string, BundleRef>,
): ClosureResult {
  const out = new Set(selected);
  const added: string[] = [];
  const stack = [...out];
  while (stack.length) {
    const key = stack.pop()!;
    for (const dep of depsOf(key, index)) {
      if (!out.has(dep)) {
        out.add(dep);
        added.push(dep);
        stack.push(dep);
      }
    }
  }
  return { selected: out, added };
}

/**
 * Bundles in `selected` (other than `key`) whose requires_bundles closure
 * includes `key` — i.e. the ones that would be left dangling if `key` were
 * removed. Drives the dependent-removal warning (spec D-6).
 */
export function dependentsOf(
  key: string,
  selected: Iterable<string>,
  index: Map<string, BundleRef>,
): string[] {
  const found: string[] = [];
  for (const cand of selected) {
    if (cand === key) continue;
    // Does cand's closure (excluding cand itself) reach key?
    const reach = closeRequires([cand], index).selected;
    reach.delete(cand);
    if (reach.has(key)) found.push(cand);
  }
  return found;
}

export interface Delta {
  /** Newly selected — not installed/kept before. */
  install: string[];
  /** Selected before and now — unchanged. */
  keep: string[];
  /** Selected before, deselected now — candidates for uninstall. */
  remove: string[];
}

/**
 * Diff a previous selection against the new one. `install`/`keep`/`remove` are
 * sorted for stable display. Caller decides whether `remove` actually uninstalls
 * (the engine never auto-removes shared deps).
 */
export function computeDelta(prev: Iterable<string>, next: Iterable<string>): Delta {
  const before = new Set(prev);
  const after = new Set(next);
  const install: string[] = [];
  const keep: string[] = [];
  const remove: string[] = [];
  for (const k of after) (before.has(k) ? keep : install).push(k);
  for (const k of before) if (!after.has(k)) remove.push(k);
  install.sort();
  keep.sort();
  remove.sort();
  return { install, keep, remove };
}
