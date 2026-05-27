import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { formatItemLabel, formatHint, buildLegend, formatTopicHeader } from '../lib/ui/format.js';

describe('formatItemLabel', () => {
  it('shows checkbox + status icon for normal item', () => {
    const opt = { value: 'x', label: 'MySQL', installed: true };
    const result = formatItemLabel(opt, true, false);
    assert.ok(result.includes('MySQL'), 'should include label');
  });

  it('shows lock icon for disabled items', () => {
    const opt = { value: 'x', label: 'Core', disabled: true };
    const result = formatItemLabel(opt, true, true);
    assert.ok(result.includes('Core'), 'should include label');
  });

  it('differs between selected and unselected', () => {
    const opt = { value: 'x', label: 'Test', installed: false };
    const selected = formatItemLabel(opt, true, false);
    const unselected = formatItemLabel(opt, false, false);
    assert.notStrictEqual(selected, unselected);
  });
});

describe('formatHint', () => {
  it('returns empty for null option', () => {
    assert.strictEqual(formatHint(null, false), '');
  });

  it('shows "deselect to remove" for installed + deselected', () => {
    const opt = { value: 'x', installed: true, desc: 'A thing' };
    const hint = formatHint(opt, false);
    assert.ok(hint.includes('deselect to remove'));
  });

  it('shows "select to install" for available + selected', () => {
    const opt = { value: 'x', installed: false, desc: 'A thing' };
    const hint = formatHint(opt, true);
    assert.ok(hint.includes('select to install'));
  });

  it('shows "installed" for installed + selected', () => {
    const opt = { value: 'x', installed: true, desc: 'A thing' };
    const hint = formatHint(opt, true);
    assert.ok(hint.includes('installed'));
  });

  it('includes desc', () => {
    const opt = { value: 'x', installed: false, desc: 'Database server' };
    const hint = formatHint(opt, false);
    assert.ok(hint.includes('Database server'));
  });

  it('includes tier', () => {
    const opt = { value: 'x', installed: true, tier: 'tier 3' };
    const hint = formatHint(opt, true);
    assert.ok(hint.includes('tier 3'));
  });

  it('includes requires', () => {
    const opt = { value: 'x', installed: false, requires: ['mysql', 'redis'] };
    const hint = formatHint(opt, false);
    assert.ok(hint.includes('mysql'));
    assert.ok(hint.includes('redis'));
  });
});

describe('buildLegend', () => {
  it('includes toggle and search instructions', () => {
    const legend = buildLegend();
    assert.ok(legend.includes('toggle'));
    assert.ok(legend.includes('search'));
  });

  it('includes installed and available labels', () => {
    const legend = buildLegend();
    assert.ok(legend.includes('installed'));
    assert.ok(legend.includes('available'));
  });
});

describe('formatTopicHeader', () => {
  it('shows index/total and installed count', () => {
    const header = formatTopicHeader('Web Stack', 0, 3, 7, 10);
    assert.ok(header.includes('1/3'), 'should show 1-based index');
    assert.ok(header.includes('Web Stack'));
    assert.ok(header.includes('7/10'));
  });
});
