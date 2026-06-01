import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import {
  readSelections,
  writeSelections,
  readParams,
  writeParams,
  quoteParam,
  serializeOptionValue,
} from '../src/core/selections-io.js';
import { tmp } from './helpers.js';

describe('selections.list', () => {
  it('round-trips, sorts, and ignores comments + blanks on read', () => {
    const f = path.join(tmp(), 'selections.list');
    writeSelections(['web/valet', 'git/config', 'web/valet'], f); // dup dropped
    const body = readFileSync(f, 'utf8');
    expect(body).toContain('# mesh selections');
    expect(body).toContain('git/config\nweb/valet'); // sorted, deduped
    const back = readSelections(f);
    expect([...back].sort()).toEqual(['git/config', 'web/valet']);
  });

  it('returns an empty set for a missing file', () => {
    expect(readSelections('/no/such/file').size).toBe(0);
  });
});

describe('params.env', () => {
  it('quotes only values bash would mis-read', () => {
    expect(quoteParam('8.4')).toBe('8.4');
    expect(quoteParam('8.4 8.5')).toBe('"8.4 8.5"');
    expect(quoteParam('')).toBe('""');
    expect(quoteParam('a$b')).toBe('"a\\$b"');
  });

  it('round-trips KEY=value with quoting', () => {
    const f = path.join(tmp(), 'params.env');
    const m = new Map([
      ['PHP_VERSIONS', '8.4 8.5'],
      ['GIT_NAME', 'Henry Avila'],
      ['INCLUDE_NPM_GLOBAL', '1'],
    ]);
    writeParams(m, f);
    const back = readParams(f);
    expect(back.get('PHP_VERSIONS')).toBe('8.4 8.5');
    expect(back.get('GIT_NAME')).toBe('Henry Avila');
    expect(back.get('INCLUDE_NPM_GLOBAL')).toBe('1');
  });
});

describe('serializeOptionValue', () => {
  it('toggle → 1/0', () => {
    expect(serializeOptionValue('toggle', true)).toBe('1');
    expect(serializeOptionValue('toggle', false)).toBe('0');
  });
  it('multiselect → space-joined, null when empty', () => {
    expect(serializeOptionValue('multiselect', ['8.4', '8.5'])).toBe('8.4 8.5');
    expect(serializeOptionValue('multiselect', [])).toBeNull();
  });
  it('text/select → value, null when empty', () => {
    expect(serializeOptionValue('text', 'Henry')).toBe('Henry');
    expect(serializeOptionValue('select', '17')).toBe('17');
    expect(serializeOptionValue('text', '')).toBeNull();
  });
});
