/**
 * scanner.ts (T-302) — per-bundle installed state, read from the engine's
 * install markers (~/.local/state/mesh/installed/<topic>__<item>.env).
 *
 * The marker is the engine's own "did mesh install this?" record
 * (install-state.sh), so reading it needs no shell-out and agrees with what the
 * engine will do on the next apply. We aggregate item-level marker presence into
 * a bundle-level state for the picker's badges:
 *
 *   installed — every platform-applicable item has a marker
 *   partial   — some but not all items have markers
 *   missing   — no item has a marker
 *
 * Item-level `when:` gating (e.g. an option-off item) can leave a legitimately
 * skipped item marker-less, which reads as `partial`; that is acceptable for a
 * status badge (selection itself comes from selections.list / default_selected,
 * not the scanner). A live driver re-probe can refine this later.
 *
 * KNOWN LIMITATION (initiative finding): markers are keyed `<topic>__<item>`, so
 * same-named items across different bundles of one topic share a marker file.
 * Such collisions over-count presence; flagged for the marker-migration fix.
 */
import { existsSync } from 'node:fs';
import path from 'node:path';
import { markersDir } from './paths.js';
import { appliesToPlatform } from './manifest-reader.js';
import type { BundleRef, Platform } from '../types.js';

export type BundleState = 'installed' | 'partial' | 'missing';

export interface BundleScan {
  key: string;
  state: BundleState;
  /** Items with a marker / total platform-applicable items. */
  installed: number;
  total: number;
}

/** Marker file path for one item, matching install-state.sh's slot rule. */
function markerPath(topicId: string, itemName: string, dir: string): string {
  return path.join(dir, `${topicId}__${itemName}.env`);
}

/** Scan one bundle's installed state from markers. */
export function scanBundle(
  ref: BundleRef,
  platform: Platform,
  dir: string = markersDir(),
): BundleScan {
  const items = ref.bundle.items.filter((i) => appliesToPlatform(i.platforms, platform));
  const total = items.length;
  let installed = 0;
  for (const item of items) {
    if (existsSync(markerPath(ref.topic.id, item.name, dir))) installed += 1;
  }
  let state: BundleState;
  if (total === 0 || installed === 0) state = 'missing';
  else if (installed === total) state = 'installed';
  else state = 'partial';
  return { key: ref.key, state, installed, total };
}

/** Scan every bundle ref → Map keyed by `topic/bundle`. */
export function scanAll(
  refs: BundleRef[],
  platform: Platform,
  dir: string = markersDir(),
): Map<string, BundleScan> {
  return new Map(refs.map((ref) => [ref.key, scanBundle(ref, platform, dir)]));
}
