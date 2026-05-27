import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import {
  readSelections,
  writeSelections,
  readParams,
  writeParams,
  selectionsToMap,
} from '../lib/core/selections-io.js';

describe('selections-io', () => {
  let tmp;
  let selPath;
  let parPath;

  it('setup temp dir', () => {
    tmp = mkdtempSync(join(tmpdir(), 'mesh-sel-'));
    selPath = join(tmp, 'selections.list');
    parPath = join(tmp, 'params.env');
  });

  describe('writeSelections + readSelections', () => {
    it('writes and reads back correctly', () => {
      const entries = ['60-web-stack/mysql-mac', '60-web-stack/redis-mac', '82-ai-tools/mdprobe'];
      writeSelections(entries, selPath);
      const result = readSelections(selPath);
      assert.deepStrictEqual(result, entries);
    });

    it('includes header comment in file', () => {
      const content = readFileSync(selPath, 'utf8');
      assert.ok(content.startsWith('#'), 'should start with comment');
      assert.ok(content.includes('Auto-generated'), 'should have auto-generated note');
    });

    it('skips comment lines on read', () => {
      const result = readSelections(selPath);
      for (const entry of result) {
        assert.ok(!entry.startsWith('#'), `entry should not be a comment: ${entry}`);
      }
    });

    it('returns null for nonexistent file', () => {
      const result = readSelections(join(tmp, 'nonexistent.list'));
      assert.strictEqual(result, null);
    });

    it('handles empty selections', () => {
      const emptyPath = join(tmp, 'empty.list');
      writeSelections([], emptyPath);
      const result = readSelections(emptyPath);
      assert.deepStrictEqual(result, []);
    });
  });

  describe('writeParams + readParams', () => {
    it('writes and reads params correctly', () => {
      const params = {
        MESH_PHP_VERSIONS: '8.4 8.5',
        MESH_CODE_DIR: '/Volumes/External/code',
        SIMPLE_KEY: 'value',
      };
      writeParams(params, parPath);
      const result = readParams(parPath);
      assert.strictEqual(result.MESH_PHP_VERSIONS, '8.4 8.5');
      assert.strictEqual(result.MESH_CODE_DIR, '/Volumes/External/code');
      assert.strictEqual(result.SIMPLE_KEY, 'value');
    });

    it('quotes values with spaces', () => {
      const content = readFileSync(parPath, 'utf8');
      assert.ok(content.includes('MESH_PHP_VERSIONS="8.4 8.5"'), 'should quote spaces');
      assert.ok(!content.includes('SIMPLE_KEY="value"'), 'should not quote simple values');
    });

    it('returns empty object for nonexistent file', () => {
      const result = readParams(join(tmp, 'nonexistent.env'));
      assert.deepStrictEqual(result, {});
    });

    it('skips comment lines', () => {
      const result = readParams(parPath);
      for (const key of Object.keys(result)) {
        assert.ok(!key.startsWith('#'), `key should not be a comment: ${key}`);
      }
    });
  });

  describe('selectionsToMap', () => {
    it('groups by topic', () => {
      const entries = ['60-web-stack/mysql-mac', '60-web-stack/redis-mac', '82-ai-tools/mdprobe'];
      const map = selectionsToMap(entries);
      assert.strictEqual(map.size, 2);
      assert.ok(map.get('60-web-stack').has('mysql-mac'));
      assert.ok(map.get('60-web-stack').has('redis-mac'));
      assert.ok(map.get('82-ai-tools').has('mdprobe'));
    });

    it('skips entries without slash', () => {
      const map = selectionsToMap(['no-slash', '60-web-stack/ok']);
      assert.strictEqual(map.size, 1);
      assert.ok(map.has('60-web-stack'));
    });

    it('handles empty input', () => {
      const map = selectionsToMap([]);
      assert.strictEqual(map.size, 0);
    });
  });

  it('cleanup temp dir', () => {
    rmSync(tmp, { recursive: true });
  });
});
