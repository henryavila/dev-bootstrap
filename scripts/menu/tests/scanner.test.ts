import { describe, it, expect } from 'vitest';
import { writeFileSync } from 'node:fs';
import path from 'node:path';
import { scanBundle } from '../src/core/scanner.js';
import { tmp } from './helpers.js';
import type { BundleRef, Topic } from '../src/types.js';

function ref(items: { name: string; platforms?: ('mac' | 'wsl' | 'linux')[] }[]): BundleRef {
  const bundle = {
    name: 'b',
    label: 'B',
    desc: 'B',
    items: items.map((i) => ({ name: i.name, type: 'custom' as const, script: './x.sh', platforms: i.platforms })),
  };
  const topic: Topic = { id: 'tp', header: { label: 'T', order: 0 }, bundles: [bundle], dir: '/tmp/tp' };
  return { topic, bundle, key: 'tp/b' };
}

function marker(dir: string, topic: string, name: string) {
  writeFileSync(path.join(dir, `${topic}__${name}.env`), 'X=1\n');
}

describe('scanBundle', () => {
  it('missing when no markers', () => {
    const dir = tmp();
    expect(scanBundle(ref([{ name: 'a' }, { name: 'b' }]), 'mac', dir).state).toBe('missing');
  });

  it('partial when some markers', () => {
    const dir = tmp();
    marker(dir, 'tp', 'a');
    const s = scanBundle(ref([{ name: 'a' }, { name: 'b' }]), 'mac', dir);
    expect(s.state).toBe('partial');
    expect(s.installed).toBe(1);
    expect(s.total).toBe(2);
  });

  it('installed when all platform-applicable markers present', () => {
    const dir = tmp();
    marker(dir, 'tp', 'a');
    // 'b' is wsl-only → not counted on mac, so only 'a' is in scope
    const s = scanBundle(ref([{ name: 'a' }, { name: 'b', platforms: ['wsl'] }]), 'mac', dir);
    expect(s.total).toBe(1);
    expect(s.state).toBe('installed');
  });
});
