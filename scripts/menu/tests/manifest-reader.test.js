import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { join, dirname } from 'node:path';
import { parseItemsYaml, readAllManifests, groupByTopic } from '../lib/core/manifest-reader.js';

const TOPICS_ROOT = join(dirname(new URL(import.meta.url).pathname), '..', '..', '..', 'topics');

describe('parseItemsYaml', () => {
  it('parses basic item', () => {
    const items = parseItemsYaml(`
- name: test
  type: brew-formula
  spec: test-pkg
  desc: "A test package"
`);
    assert.strictEqual(items.length, 1);
    assert.strictEqual(items[0].name, 'test');
    assert.strictEqual(items[0].type, 'brew-formula');
    assert.strictEqual(items[0].spec, 'test-pkg');
  });

  it('parses platform list', () => {
    const items = parseItemsYaml(`
- name: x
  type: apt
  platforms: [mac, wsl]
`);
    assert.deepStrictEqual(items[0].platforms, ['mac', 'wsl']);
  });

  it('parses requires list', () => {
    const items = parseItemsYaml(`
- name: valet
  type: custom
  requires: [mysql-mac, redis-mac]
`);
    assert.deepStrictEqual(items[0].requires, ['mysql-mac', 'redis-mac']);
  });

  it('parses boolean and number fields', () => {
    const items = parseItemsYaml(`
- name: core
  type: custom
  required: true
  uninstall_tier: 3
`);
    assert.strictEqual(items[0].required, true);
    assert.strictEqual(items[0].uninstall_tier, 3);
  });

  it('skips comments', () => {
    const items = parseItemsYaml(`
# This is a comment
- name: x
  type: apt
  # Another comment
  spec: pkg
`);
    assert.strictEqual(items.length, 1);
  });

  it('handles multiple items', () => {
    const items = parseItemsYaml(`
- name: a
  type: apt

- name: b
  type: brew-formula
`);
    assert.strictEqual(items.length, 2);
    assert.strictEqual(items[0].name, 'a');
    assert.strictEqual(items[1].name, 'b');
  });
});

describe('readAllManifests', () => {
  it('reads real topics', () => {
    const items = readAllManifests(TOPICS_ROOT);
    assert.ok(items.length > 0, 'should find items');
    const names = items.map((i) => i.name);
    assert.ok(names.includes('fzf-mac'), 'should include fzf-mac');
  });

  it('filters by platform', () => {
    const macItems = readAllManifests(TOPICS_ROOT, { platform: 'mac' });
    const wslItems = readAllManifests(TOPICS_ROOT, { platform: 'wsl' });
    const macOnly = macItems.filter((i) => i.platforms.length > 0 && !i.platforms.includes('wsl'));
    assert.ok(macOnly.length > 0, 'should have mac-only items');
    for (const item of wslItems) {
      if (item.platforms.length > 0) {
        assert.ok(item.platforms.includes('wsl'), `${item.name} should be wsl-compatible`);
      }
    }
  });

  it('preserves requires field', () => {
    const items = readAllManifests(TOPICS_ROOT, { platform: 'mac' });
    const valet = items.find((i) => i.name === 'valet');
    assert.ok(valet, 'valet should exist');
    assert.ok(valet.requires.includes('mysql-mac'), 'valet requires mysql-mac');
  });
});

describe('groupByTopic', () => {
  it('groups items by topic', () => {
    const items = [
      { topic: 'a', name: 'x' },
      { topic: 'a', name: 'y' },
      { topic: 'b', name: 'z' },
    ];
    const groups = groupByTopic(items);
    assert.strictEqual(groups.size, 2);
    assert.strictEqual(groups.get('a').length, 2);
    assert.strictEqual(groups.get('b').length, 1);
  });
});
