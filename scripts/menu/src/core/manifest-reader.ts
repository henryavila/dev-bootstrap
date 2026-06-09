/**
 * manifest-reader.ts (T-301) — read every topics/<id>/manifest.yaml into typed
 * Topic[] structures. The complement to the bash yaml-parse.sh: same schema,
 * read independently for the TS menu UI.
 *
 * Robust YAML (the `yaml` package) over the v1 hand-rolled reader — the v2
 * schema is 3-level (topic → bundles → items + options) with nested option
 * choices, which a line matcher cannot parse safely.
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { parse as parseYaml } from 'yaml';
import { TOPICS_DIR } from './paths.js';
import type { Bundle, BundleRef, Platform, Topic } from '../types.js';

export class ManifestError extends Error {
  constructor(
    public readonly file: string,
    message: string,
  ) {
    super(`${file}: ${message}`);
    this.name = 'ManifestError';
  }
}

/** Parse one manifest.yaml file into a Topic (id = its directory name). */
export function readTopicManifest(file: string, id: string, dir: string): Topic {
  let raw: unknown;
  try {
    raw = parseYaml(readFileSync(file, 'utf8'));
  } catch (err) {
    throw new ManifestError(file, `invalid YAML — ${(err as Error).message}`);
  }
  if (raw === null || typeof raw !== 'object') {
    throw new ManifestError(file, 'manifest is empty or not a mapping');
  }
  const doc = raw as Record<string, unknown>;
  const header = doc.topic as Topic['header'] | undefined;
  if (!header || typeof header !== 'object') {
    throw new ManifestError(file, 'missing `topic:` block');
  }
  if (typeof header.label !== 'string' || typeof header.order !== 'number') {
    throw new ManifestError(file, '`topic` requires `label` and a numeric `order`');
  }
  const bundles = doc.bundles;
  if (!Array.isArray(bundles) || bundles.length === 0) {
    throw new ManifestError(file, '`bundles:` must be a non-empty list');
  }
  for (const b of bundles as Bundle[]) {
    if (typeof b.name !== 'string' || typeof b.label !== 'string') {
      throw new ManifestError(file, 'each bundle needs `name` and `label`');
    }
    if (!Array.isArray(b.items) || b.items.length === 0) {
      throw new ManifestError(file, `bundle "${b.name}" has no items`);
    }
  }
  return { id, header, bundles: bundles as Bundle[], dir };
}

/** Read every topics/<id>/manifest.yaml, sorted by topic.order then id. */
export function readAllManifests(topicsDir: string = TOPICS_DIR): Topic[] {
  const topics: Topic[] = [];
  for (const entry of readdirSync(topicsDir)) {
    const dir = path.join(topicsDir, entry);
    if (!statSync(dir).isDirectory()) continue;
    const file = path.join(dir, 'manifest.yaml');
    try {
      statSync(file);
    } catch {
      continue; // a topic dir without a manifest — skip (e.g. shared assets)
    }
    topics.push(readTopicManifest(file, entry, dir));
  }
  topics.sort((a, b) => a.header.order - b.header.order || a.id.localeCompare(b.id));
  return topics;
}

/** True if a bundle (or item) with the given platforms list applies to `platform`. */
export function appliesToPlatform(
  platforms: Platform[] | undefined,
  platform: Platform,
): boolean {
  if (!platforms || platforms.length === 0) return true;
  if (platforms.includes(platform)) return true;
  // `linux` is the umbrella for any Linux host; `wsl` is a Linux subtype.
  if (platform === 'wsl' && platforms.includes('linux')) return true;
  return false;
}

/**
 * Topics keeping only the bundles that apply to `platform`. A topic whose every
 * bundle is platform-excluded is dropped entirely.
 */
export function filterByPlatform(topics: Topic[], platform: Platform): Topic[] {
  const out: Topic[] = [];
  for (const t of topics) {
    const bundles = t.bundles.filter((b) => appliesToPlatform(b.platforms, platform));
    if (bundles.length > 0) out.push({ ...t, bundles });
  }
  return out;
}

/** Flatten topics into `topic/bundle` refs, preserving topic+bundle order. */
export function flattenBundles(topics: Topic[]): BundleRef[] {
  const refs: BundleRef[] = [];
  for (const topic of topics) {
    for (const bundle of topic.bundles) {
      refs.push({ topic, bundle, key: `${topic.id}/${bundle.name}` });
    }
  }
  return refs;
}

/** Index bundle refs by their `topic/bundle` key. */
export function indexByKey(refs: BundleRef[]): Map<string, BundleRef> {
  return new Map(refs.map((r) => [r.key, r]));
}
