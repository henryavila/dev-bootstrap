import { describe, it, expect } from 'vitest';
import { buildFormSpec, applyFormValues, resolveSelectedDefaults } from '../src/core/form-spec.js';
import { readAllManifests, flattenBundles, indexByKey } from '../src/core/manifest-reader.js';
import type { BundleRef } from '../src/types.js';

const index = indexByKey(flattenBundles(readAllManifests()));

describe('buildFormSpec — languages/php (source file + derive_from)', () => {
  const php = index.get('languages/php')!;
  const spec = buildFormSpec(php.bundle, php.topic.dir);

  it('reads PHP versions from the source file into multiselect choices', () => {
    const versions = spec.fields.find((f) => f.name === 'versions')!;
    expect(versions.kind).toBe('multiselect');
    const ids = (versions.choices ?? []).map((c) => (typeof c === 'string' ? c : c.id));
    expect(ids).toEqual(expect.arrayContaining(['8.2', '8.3', '8.4', '8.5']));
    expect(versions.min).toBe(1); // required_min
  });

  it('maps derive_from → optionsFrom on the default-version select', () => {
    const dv = spec.fields.find((f) => f.name === 'default-version')!;
    expect(dv.kind).toBe('select');
    expect(dv.optionsFrom).toBe('versions');
  });

  it('seeds the multiselect default from the manifest', () => {
    expect(spec.values['versions']).toEqual(['8.4']);
  });
});

describe('buildFormSpec — existing params.env override', () => {
  const php = index.get('languages/php')!;
  it('pre-fills from an existing PHP_VERSIONS over the schema default', () => {
    const spec = buildFormSpec(php.bundle, php.topic.dir, new Map([['PHP_VERSIONS', '8.3 8.5']]));
    expect(spec.values['versions']).toEqual(['8.3', '8.5']);
  });
});

describe('applyFormValues → params', () => {
  it('serialises values to env vars; clears emptied keys', () => {
    const php = index.get('languages/php')!;
    const spec = buildFormSpec(php.bundle, php.topic.dir);
    const params = new Map<string, string>();
    applyFormValues(spec, { versions: ['8.4', '8.5'], 'default-version': '8.5' }, params);
    expect(params.get('PHP_VERSIONS')).toBe('8.4 8.5');
    expect(params.get('PHP_DEFAULT')).toBe('8.5');

    applyFormValues(spec, { versions: [], 'default-version': '' }, params);
    expect(params.has('PHP_VERSIONS')).toBe(false);
  });
});

describe('buildFormSpec — git/config (default_from runs a command)', () => {
  it('exposes text fields with the right env mapping', () => {
    const git = index.get('git/config')!;
    const spec = buildFormSpec(git.bundle, git.topic.dir);
    const name = spec.fields.find((f) => f.name === 'user-name')!;
    expect(name.kind).toBe('text');
    expect(spec.envByName.get('user-name')!.env).toBe('GIT_NAME');
    // default_from value is whatever `git config` returns (possibly ''), a string
    expect(typeof spec.values['user-name']).toBe('string');
  });
});

describe('resolveSelectedDefaults — persist defaults without opening the form (T-500 footgun)', () => {
  const makeRef = (options: unknown[]): BundleRef =>
    ({ key: 't/b', topic: { id: 't', dir: '/tmp' }, bundle: { name: 'b', options } }) as unknown as BundleRef;
  const modeOpt = { name: 'mode', type: 'select', label: 'Mode', env: 'X_MODE', default: 'fast' };

  it('fills a selected bundle option default into params', () => {
    const params = new Map<string, string>();
    resolveSelectedDefaults([makeRef([modeOpt])], params);
    expect(params.get('X_MODE')).toBe('fast');
  });

  it('never overwrites a value the user already set', () => {
    const params = new Map([['X_MODE', 'slow']]);
    resolveSelectedDefaults([makeRef([modeOpt])], params);
    expect(params.get('X_MODE')).toBe('slow');
  });

  it('is a no-op for a bundle with no options', () => {
    const params = new Map<string, string>();
    resolveSelectedDefaults([makeRef([])], params);
    expect(params.size).toBe(0);
  });
});
