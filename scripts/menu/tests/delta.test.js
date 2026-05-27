import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import {
  computeDelta,
  validateDependencies,
  autoSelectDependencies,
  canRemove,
} from '../lib/core/delta.js';

describe('computeDelta', () => {
  it('classifies install/remove/keep correctly', () => {
    const d = computeDelta(
      [],
      ['a/x', 'a/y'],
      ['a/x', 'a/z'],
    );
    assert.deepStrictEqual(d.keep, ['a/x']);
    assert.deepStrictEqual(d.install, ['a/z']);
    assert.deepStrictEqual(d.remove, ['a/y']);
  });

  it('handles null previousSelections', () => {
    const d = computeDelta([], null, ['a/x']);
    assert.deepStrictEqual(d.install, ['a/x']);
    assert.deepStrictEqual(d.remove, []);
    assert.deepStrictEqual(d.keep, []);
  });

  it('handles empty new selections', () => {
    const d = computeDelta([], ['a/x'], []);
    assert.deepStrictEqual(d.install, []);
    assert.deepStrictEqual(d.remove, ['a/x']);
  });
});

describe('validateDependencies', () => {
  const manifest = [
    { topic: 't', name: 'valet', requires: ['mysql', 'redis'] },
    { topic: 't', name: 'mysql', requires: [] },
    { topic: 't', name: 'redis', requires: [] },
  ];

  it('returns errors for missing deps', () => {
    const errors = validateDependencies(manifest, ['t/valet']);
    assert.strictEqual(errors.length, 2);
  });

  it('returns no errors when deps are present', () => {
    const errors = validateDependencies(manifest, ['t/valet', 't/mysql', 't/redis']);
    assert.strictEqual(errors.length, 0);
  });
});

describe('autoSelectDependencies', () => {
  const manifest = [
    { topic: 't', name: 'valet', requires: ['mysql', 'redis'] },
    { topic: 't', name: 'mysql', requires: [] },
    { topic: 't', name: 'redis', requires: [] },
  ];

  it('auto-selects missing deps', () => {
    const { selected, added } = autoSelectDependencies(manifest, ['t/valet']);
    assert.strictEqual(added.length, 2);
    assert.ok(selected.includes('t/mysql'));
    assert.ok(selected.includes('t/redis'));
  });

  it('does not duplicate existing deps', () => {
    const { added } = autoSelectDependencies(manifest, ['t/valet', 't/mysql', 't/redis']);
    assert.strictEqual(added.length, 0);
  });
});

describe('canRemove', () => {
  const manifest = [
    { topic: 't', name: 'valet', requires: ['mysql'] },
    { topic: 't', name: 'mysql', requires: [] },
  ];

  it('blocks removal when dependents exist', () => {
    const result = canRemove(manifest, 't/mysql', ['t/mysql', 't/valet']);
    assert.strictEqual(result.allowed, false);
    assert.deepStrictEqual(result.blockers, ['t/valet']);
  });

  it('allows removal when no dependents', () => {
    const result = canRemove(manifest, 't/mysql', ['t/mysql']);
    assert.strictEqual(result.allowed, true);
  });
});
