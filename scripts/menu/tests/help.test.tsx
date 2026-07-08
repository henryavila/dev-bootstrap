/**
 * help.test.tsx — the `mesh help` command browser. Covers the runner→TUI
 * contract: parse command TSV, filter by command/group/summary, render command
 * metadata plus precomputed help text, and exit cleanly on Esc/q.
 */
import { describe, it, expect, beforeAll } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '@henryavila/blink-tui';
import { HelpBrowser, parseCommandsTsv, filterCommands } from '../src/screens/HelpBrowser.js';
import { parseHelpArgs } from '../src/help-main.js';
import { registerDomainGlyphs } from '../src/glyphs.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
beforeAll(() => registerDomainGlyphs());

const TSV = [
  'clean\tReclaim regenerable dev caches\tcore\tcore\tpublic\tnone',
  'services\tControl mesh-owned daemons\tcore\tcore\tpublic\tallowed',
  'update\tPull and apply mesh updates\tcore\tcore\tpublic\tallowed',
].join('\n');

const DETAILS = new Map([
  ['clean', ['Usage:', '  mesh clean', '', 'Dry-run cache reclaim.']],
  ['services', ['Usage:', '  mesh services list', '', 'Control daemons.']],
  ['update', ['Usage:', '  mesh update', '', 'Pull updates.']],
]);

describe('parseCommandsTsv', () => {
  const commands = parseCommandsTsv(TSV);
  it('parses the six registry fields', () => {
    expect(commands).toHaveLength(3);
    expect(commands[1]).toMatchObject({
      name: 'services',
      summary: 'Control mesh-owned daemons',
      group: 'core',
      origin: 'core',
      visibility: 'public',
      fanout: 'allowed',
    });
  });
  it('drops blank and name-less rows', () => {
    expect(parseCommandsTsv('\n\tbad\tcore\tcore\tpublic\tnone\nok\tOK\tcore\tcore\tpublic\tnone')).toHaveLength(1);
  });
});

describe('filterCommands', () => {
  const commands = parseCommandsTsv(TSV);
  it('empty query returns everything', () => {
    expect(filterCommands(commands, '')).toHaveLength(3);
  });
  it('matches name, summary and group case-insensitively', () => {
    expect(filterCommands(commands, 'serv').map((c) => c.name)).toEqual(['services']);
    expect(filterCommands(commands, 'caches').map((c) => c.name)).toEqual(['clean']);
    expect(filterCommands(commands, 'CORE')).toHaveLength(3);
  });
});

describe('parseHelpArgs', () => {
  it('parses command TSV, detail dir and selected command', () => {
    expect(parseHelpArgs(['--commands', '/tmp/c', '--details-dir', '/tmp/d', '--selected', 'update'])).toEqual({
      commands: '/tmp/c',
      detailsDir: '/tmp/d',
      selected: 'update',
    });
  });
  it('null when required args are missing', () => {
    expect(parseHelpArgs(['--commands', '/tmp/c'])).toBeNull();
    expect(parseHelpArgs([])).toBeNull();
  });
});

describe('HelpBrowser (render + keys)', () => {
  function mount(selected?: string) {
    const calls: number[] = [];
    const r = render(
      <ThemeProvider iconSet="unicode">
        <HelpBrowser
          commands={parseCommandsTsv(TSV)}
          details={DETAILS}
          selected={selected}
          onExit={(code = 0) => calls.push(code)}
        />
      </ThemeProvider>,
    );
    return { ...r, calls };
  }

  it('lists commands and shows focused command detail', () => {
    const f = mount().lastFrame() ?? '';
    expect(f).toContain('clean');
    expect(f).toContain('services');
    expect(f).toContain('Usage:');
    expect(f).toContain('mesh clean');
  });

  it('starts focused on the selected command when provided', () => {
    const f = mount('update').lastFrame() ?? '';
    expect(f).toContain('Pull updates.');
    expect(f).toContain('mesh update --help');
  });

  it('filters live as you type', async () => {
    const { stdin, lastFrame } = mount();
    await delay(20);
    stdin.write('serv');
    await delay(20);
    const f = lastFrame() ?? '';
    expect(f).toContain('services');
    expect(f).toContain('Control daemons.');
    expect(f).not.toContain('clean');
  });

  it('Esc exits with code 0', async () => {
    const { stdin, calls } = mount();
    await delay(20);
    stdin.write('\x1B');
    await delay(20);
    expect(calls).toEqual([0]);
  });
});
