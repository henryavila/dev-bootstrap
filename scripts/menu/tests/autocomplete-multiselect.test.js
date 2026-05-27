import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { AutocompleteMultiselectPrompt } from '../lib/ui/autocomplete-multiselect.js';

function makePrompt(overrides = {}) {
  const defaults = {
    options: [
      { value: 'mysql', label: 'MySQL 8', desc: 'Database server', installed: true },
      { value: 'redis', label: 'Redis', desc: 'In-memory cache', installed: true },
      { value: 'ngrok', label: 'ngrok', desc: 'Tunnel service', installed: false },
      { value: 'postgres', label: 'PostgreSQL', desc: 'Database server', installed: false },
    ],
    initialValues: ['mysql', 'redis'],
    render() { return ''; },
  };
  return new AutocompleteMultiselectPrompt({ ...defaults, ...overrides });
}

describe('AutocompleteMultiselectPrompt', () => {
  describe('initial state', () => {
    it('sets initial values from initialValues', () => {
      const p = makePrompt();
      const vals = p._value;
      assert.strictEqual(vals.length, 2);
      assert.ok(vals.includes('mysql'));
      assert.ok(vals.includes('redis'));
    });

    it('shows all items unfiltered', () => {
      const p = makePrompt();
      assert.strictEqual(p.filteredIndices.length, 4);
    });

    it('cursor starts at 0', () => {
      const p = makePrompt();
      assert.strictEqual(p.cursor, 0);
    });

    it('search starts empty', () => {
      const p = makePrompt();
      assert.strictEqual(p.search, '');
    });
  });

  describe('filtering', () => {
    it('filters by label', () => {
      const p = makePrompt();
      p.search = 'post';
      p._refilter();
      assert.strictEqual(p.filteredIndices.length, 1);
      assert.strictEqual(p.options[p.filteredIndices[0]].value, 'postgres');
    });

    it('filters by desc', () => {
      const p = makePrompt();
      p.search = 'database';
      p._refilter();
      assert.strictEqual(p.filteredIndices.length, 2);
    });

    it('is case-insensitive', () => {
      const p = makePrompt();
      p.search = 'REDIS';
      p._refilter();
      assert.strictEqual(p.filteredIndices.length, 1);
    });

    it('shows all when search is empty', () => {
      const p = makePrompt();
      p.search = 'xyz';
      p._refilter();
      assert.strictEqual(p.filteredIndices.length, 0);
      p.search = '';
      p._refilter();
      assert.strictEqual(p.filteredIndices.length, 4);
    });

    it('clamps cursor to filtered results', () => {
      const p = makePrompt();
      p.cursor = 3;
      p.search = 'mysql';
      p._refilter();
      assert.strictEqual(p.cursor, 0);
    });

    it('handles no matches gracefully', () => {
      const p = makePrompt();
      p.search = 'zzzzz';
      p._refilter();
      assert.strictEqual(p.filteredIndices.length, 0);
      assert.strictEqual(p.cursor, 0);
    });
  });

  describe('toggling', () => {
    it('selects an unselected item', () => {
      const p = makePrompt();
      p.cursor = 2; // ngrok (unselected)
      p._toggle();
      assert.ok(p._value.includes('ngrok'));
    });

    it('deselects a selected item', () => {
      const p = makePrompt();
      p.cursor = 1; // redis (selected)
      p._toggle();
      assert.ok(!p._value.includes('redis'));
    });

    it('does not toggle disabled items', () => {
      const p = makePrompt({
        options: [
          { value: 'core', label: 'Core', disabled: true },
          { value: 'opt', label: 'Optional' },
        ],
        initialValues: ['core'],
      });
      p.cursor = 0;
      p._toggle();
      assert.ok(p._value.includes('core'), 'disabled item should stay selected');
    });

    it('does nothing when no filtered items', () => {
      const p = makePrompt();
      p.search = 'zzzzz';
      p._refilter();
      p._toggle(); // should not throw
      assert.strictEqual(p._value.length, 2);
    });

    it('toggles correct item after filtering', () => {
      const p = makePrompt();
      p.search = 'ngrok';
      p._refilter();
      p.cursor = 0;
      p._toggle();
      assert.ok(p._value.includes('ngrok'));
      assert.strictEqual(p._value.length, 3);
    });
  });

  describe('focusedOption', () => {
    it('returns the focused option', () => {
      const p = makePrompt();
      p.cursor = 2;
      const focused = p.focusedOption();
      assert.strictEqual(focused.value, 'ngrok');
    });

    it('returns null when no matches', () => {
      const p = makePrompt();
      p.search = 'zzzzz';
      p._refilter();
      assert.strictEqual(p.focusedOption(), null);
    });
  });

  describe('focusedRealIndex', () => {
    it('returns real index in original options array', () => {
      const p = makePrompt();
      p.search = 'post';
      p._refilter();
      p.cursor = 0;
      assert.strictEqual(p.focusedRealIndex(), 3); // postgres is at index 3
    });

    it('returns -1 when no matches', () => {
      const p = makePrompt();
      p.search = 'zzzzz';
      p._refilter();
      assert.strictEqual(p.focusedRealIndex(), -1);
    });
  });

  describe('isSelected', () => {
    it('returns true for selected items', () => {
      const p = makePrompt();
      assert.strictEqual(p.isSelected(0), true);  // mysql
      assert.strictEqual(p.isSelected(1), true);  // redis
    });

    it('returns false for unselected items', () => {
      const p = makePrompt();
      assert.strictEqual(p.isSelected(2), false);  // ngrok
      assert.strictEqual(p.isSelected(3), false);  // postgres
    });
  });
});
