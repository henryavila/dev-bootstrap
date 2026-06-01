/** Test helpers — synthetic bundle index + a tmp dir maker. */
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import type { Bundle, BundleRef, Topic } from '../src/types.js';

/** Build a synthetic index from `topic/bundle` → its requires_bundles. */
export function makeIndex(
  spec: Record<string, { requires?: string[]; required?: boolean }>,
): Map<string, BundleRef> {
  const index = new Map<string, BundleRef>();
  for (const [key, cfg] of Object.entries(spec)) {
    const [topicId, bundleName] = key.split('/');
    const bundle: Bundle = {
      name: bundleName,
      label: bundleName,
      desc: bundleName,
      items: [{ name: 'x', type: 'custom', script: './x.sh' }],
      requires_bundles: cfg.requires,
      required: cfg.required,
    };
    const topic: Topic = {
      id: topicId,
      header: { label: topicId, order: 0 },
      bundles: [bundle],
      dir: `/tmp/${topicId}`,
    };
    index.set(key, { topic, bundle, key });
  }
  return index;
}

export function tmp(): string {
  return mkdtempSync(path.join(tmpdir(), 'mesh-menu-test-'));
}
