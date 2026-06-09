import { describe, it, expect } from 'vitest';
import { closeRequires, dependentsOf, computeDelta, toggleTopicSelection } from '../src/core/delta.js';
import { makeIndex } from './helpers.js';

const index = makeIndex({
  'web/valet': { requires: ['databases/mysql', 'databases/redis'] },
  'web/nginx': { requires: ['languages/php'] },
  'databases/mysql': {},
  'databases/redis': {},
  'languages/php': {},
  'shell/zsh': { requires: ['shell/cli'] },
  'shell/cli': {},
});

describe('closeRequires', () => {
  it('adds transitive deps and reports what was added', () => {
    const { selected, added } = closeRequires(['web/valet'], index);
    expect([...selected].sort()).toEqual(['databases/mysql', 'databases/redis', 'web/valet']);
    expect(added.sort()).toEqual(['databases/mysql', 'databases/redis']);
  });

  it('adds nothing when deps already present', () => {
    const { added } = closeRequires(['databases/mysql', 'web/valet', 'databases/redis'], index);
    expect(added).toEqual([]);
  });

  it('ignores requires targets missing from the index (defensive)', () => {
    const i = makeIndex({ 'a/b': { requires: ['ghost/x'] } });
    const { selected } = closeRequires(['a/b'], i);
    expect([...selected]).toEqual(['a/b']);
  });

  it('terminates on a cycle', () => {
    const i = makeIndex({ 'a/x': { requires: ['b/y'] }, 'b/y': { requires: ['a/x'] } });
    const { selected } = closeRequires(['a/x'], i);
    expect([...selected].sort()).toEqual(['a/x', 'b/y']);
  });
});

describe('dependentsOf', () => {
  it('finds selected bundles that (transitively) require the target', () => {
    const sel = ['web/valet', 'databases/mysql', 'databases/redis'];
    expect(dependentsOf('databases/mysql', sel, index)).toEqual(['web/valet']);
  });

  it('returns none when nothing selected depends on it', () => {
    expect(dependentsOf('languages/php', ['databases/mysql'], index)).toEqual([]);
  });
});

describe('computeDelta', () => {
  it('splits into install / keep / remove, sorted', () => {
    const d = computeDelta(['a', 'b', 'c'], ['b', 'c', 'd']);
    expect(d.install).toEqual(['d']);
    expect(d.keep).toEqual(['b', 'c']);
    expect(d.remove).toEqual(['a']);
  });

  it('fresh install (empty prev) makes everything install', () => {
    const d = computeDelta([], ['x', 'y']);
    expect(d.install).toEqual(['x', 'y']);
    expect(d.remove).toEqual([]);
  });
});

describe('toggleTopicSelection (Space on a topic = toggle-all, not toggle-first)', () => {
  const idx = makeIndex({
    'db/mysql': {},
    'db/redis': {},
    'web/valet': { requires: ['db/mysql', 'db/redis'] },
    'shell/zsh': { requires: ['shell/cli'] },
    'shell/cli': {},
  });
  const dbKeys = ['db/mysql', 'db/redis'];

  it('selects ALL bundles of the topic when none are selected (the bug: only the first toggled)', () => {
    const res = toggleTopicSelection(dbKeys, new Set(), new Set(), idx);
    expect([...res.selected].sort()).toEqual(['db/mysql', 'db/redis']);
    expect(res.removed).toEqual([]);
  });

  it('fills the rest when the topic is only partially selected', () => {
    const res = toggleTopicSelection(dbKeys, new Set(), new Set(['db/mysql']), idx);
    expect([...res.selected].sort()).toEqual(['db/mysql', 'db/redis']);
  });

  it('deselects ALL bundles of the topic when every one is already selected', () => {
    const res = toggleTopicSelection(dbKeys, new Set(), new Set(['db/mysql', 'db/redis']), idx);
    expect([...res.selected]).toEqual([]);
    expect(res.removed.sort()).toEqual(['db/mysql', 'db/redis']);
  });

  it('pulls the requires_bundles closure when selecting a topic', () => {
    const res = toggleTopicSelection(['shell/zsh'], new Set(), new Set(), idx);
    expect([...res.selected].sort()).toEqual(['shell/cli', 'shell/zsh']);
    expect(res.added).toEqual(['shell/cli']);
  });

  it('removes dangling dependents when deselecting a depended-on topic', () => {
    const sel = new Set(['db/mysql', 'db/redis', 'web/valet']);
    const res = toggleTopicSelection(dbKeys, new Set(), sel, idx);
    expect(res.selected.has('web/valet')).toBe(false); // valet needs db/* → dropped
    expect(res.selected.has('db/mysql')).toBe(false);
    expect(res.selected.has('db/redis')).toBe(false);
  });

  it('never toggles required/locked bundles', () => {
    // db/mysql is required (locked); only db/redis is selectable.
    const res = toggleTopicSelection(dbKeys, new Set(['db/mysql']), new Set(['db/mysql', 'db/redis']), idx);
    expect(res.selected.has('db/mysql')).toBe(true); // untouched
    expect(res.selected.has('db/redis')).toBe(false); // the only selectable → toggled off
  });

  it('is a no-op when the topic has only required bundles', () => {
    const res = toggleTopicSelection(['db/mysql'], new Set(['db/mysql']), new Set(['db/mysql']), idx);
    expect([...res.selected]).toEqual(['db/mysql']);
    expect(res.added).toEqual([]);
    expect(res.removed).toEqual([]);
  });
});
