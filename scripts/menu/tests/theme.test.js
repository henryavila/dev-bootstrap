import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { icons, status, symbol, pc } from '../lib/ui/theme.js';

describe('theme', () => {
  describe('icons', () => {
    it('exports all required icon constants', () => {
      const required = [
        'installed', 'available', 'willRemove', 'locked', 'diamond',
        'diamondOpen', 'square', 'warning', 'bar', 'end',
        'checkboxOn', 'checkboxOff', 'radio', 'radioOff',
      ];
      for (const key of required) {
        assert.ok(icons[key] !== undefined, `icons.${key} should be defined`);
        assert.ok(typeof icons[key] === 'string', `icons.${key} should be a string`);
      }
    });
  });

  describe('status helpers', () => {
    it('installed() returns a string with the text', () => {
      const result = status.installed('MySQL');
      assert.ok(result.includes('MySQL'));
    });

    it('available() returns a string with the text', () => {
      const result = status.available('ngrok');
      assert.ok(result.includes('ngrok'));
    });

    it('willRemove() returns a string with the text', () => {
      const result = status.willRemove('redis');
      assert.ok(result.includes('redis'));
    });

    it('required() returns a string with the text', () => {
      const result = status.required('core');
      assert.ok(result.includes('core'));
    });
  });

  describe('symbol', () => {
    it('returns different symbols for each state', () => {
      const states = ['initial', 'active', 'cancel', 'error', 'submit'];
      const results = states.map((s) => symbol(s));
      const unique = new Set(results);
      assert.ok(unique.size >= 3, 'should have at least 3 distinct symbols');
    });

    it('returns a string for every state', () => {
      for (const s of ['initial', 'active', 'cancel', 'error', 'submit']) {
        assert.ok(typeof symbol(s) === 'string', `symbol(${s}) should be string`);
      }
    });
  });

  describe('pc (picocolors)', () => {
    it('exports picocolors', () => {
      assert.ok(typeof pc.green === 'function');
      assert.ok(typeof pc.red === 'function');
      assert.ok(typeof pc.dim === 'function');
      assert.ok(typeof pc.cyan === 'function');
    });
  });
});
