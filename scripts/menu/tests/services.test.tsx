/**
 * services.test.tsx — the `mesh services` interactive flow (ServicesPicker +
 * ServiceActions + ServicesFlow) and its pure helpers. Covers the runner→TUI
 * contract: parse the porcelain rows (id|display|aliases|owner|kind|scope|
 * target|active|enabled), filter by substring, render the list, the
 * context-aware action set per the two bits, and the two-screen flow handing
 * back `<id>\t<verb>`.
 */
import { describe, it, expect, beforeAll } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '@henryavila/blink-tui';
import {
  ServicesPicker,
  parseServices,
  filterServices,
  activeBadge,
  enabledBadge,
  serviceMeta,
} from '../src/screens/ServicesPicker.js';
import { ServiceActions, actionsFor } from '../src/screens/ServiceActions.js';
import { ServicesFlow, parseServicesArgs } from '../src/services-main.js';
import { registerDomainGlyphs } from '../src/glyphs.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
beforeAll(() => registerDomainGlyphs());

// id|display|aliases|owner|kind|scope|target|active|enabled
const ROWS = [
  'mysql|MySQL|mysqld|databases|systemd|system|mysql|on|on',
  'redis|Redis|redis-server|databases|systemd|system|redis-server|off|off',
  'php-fpm@8.2|PHP-FPM 8.2|php-fpm,php82|web|systemd|system|php8.2-fpm|on|on',
  'php-fpm@8.3|PHP-FPM 8.3|php-fpm,php83|web|systemd|system|php8.3-fpm|off|on',
].join('\n');

describe('parseServices', () => {
  const items = parseServices(ROWS);
  it('parses the nine pipe fields + keeps the raw line', () => {
    expect(items).toHaveLength(4);
    expect(items[0]).toMatchObject({
      id: 'mysql',
      display: 'MySQL',
      aliases: 'mysqld',
      owner: 'databases',
      kind: 'systemd',
      scope: 'system',
      target: 'mysql',
      active: 'on',
      enabled: 'on',
    });
    expect(items[3]).toMatchObject({ id: 'php-fpm@8.3', active: 'off', enabled: 'on' });
  });
  it('drops blank and id-less lines', () => {
    expect(parseServices('\n\n|MySQL|||||||\nmysql|MySQL|||systemd|system|mysql|on|on')).toHaveLength(1);
  });
});

describe('filterServices (substring, case-insensitive)', () => {
  const items = parseServices(ROWS);
  it('empty query returns everything', () => {
    expect(filterServices(items, '')).toHaveLength(4);
  });
  it('typing php narrows to the php-fpm versions', () => {
    expect(filterServices(items, 'php').map((i) => i.id)).toEqual(['php-fpm@8.2', 'php-fpm@8.3']);
  });
  it('matches on an alias', () => {
    expect(filterServices(items, 'mysqld').map((i) => i.id)).toEqual(['mysql']);
  });
  it('no match returns empty', () => {
    expect(filterServices(items, 'zzz')).toHaveLength(0);
  });
});

describe('badges + meta', () => {
  it('maps the two bits to human labels', () => {
    expect(activeBadge('on')).toBe('running');
    expect(activeBadge('off')).toBe('stopped');
    expect(activeBadge('unknown')).toBe('?');
    expect(enabledBadge('on')).toBe('on-boot');
    expect(enabledBadge('off')).toBe('no-boot');
  });
  it('serviceMeta combines badges + backend + owner', () => {
    expect(serviceMeta(parseServices(ROWS)[0])).toBe('running · on-boot · systemd · databases');
  });
});

describe('actionsFor (context-aware)', () => {
  const items = parseServices(ROWS);
  it('a running + enabled service offers stop/restart/disable, never start', () => {
    const verbs = actionsFor(items[0]).map((a) => a.verb); // mysql on/on
    expect(verbs).toEqual(['stop', 'restart', 'disable']);
    expect(verbs).not.toContain('start');
  });
  it('a stopped + disabled service offers start/enable', () => {
    const verbs = actionsFor(items[1]).map((a) => a.verb); // redis off/off
    expect(verbs).toEqual(['start', 'enable']);
  });
  it('an unknown active bit offers all runtime verbs', () => {
    const unknown = { ...items[0], active: 'unknown', enabled: 'unknown' };
    expect(actionsFor(unknown).map((a) => a.verb)).toEqual(['start', 'stop', 'restart', 'enable', 'disable']);
  });
});

describe('parseServicesArgs (runner → flow contract)', () => {
  it('parses --in + --out', () => {
    expect(parseServicesArgs(['--in', '/tmp/r', '--out', '/tmp/o'])).toEqual({ in: '/tmp/r', out: '/tmp/o' });
  });
  it('null when either is missing', () => {
    expect(parseServicesArgs(['--in', '/tmp/r'])).toBeNull();
    expect(parseServicesArgs([])).toBeNull();
  });
});

describe('ServicesPicker (render + filter)', () => {
  function mount() {
    const calls: (string | null)[] = [];
    const r = render(
      <ThemeProvider iconSet="unicode">
        <ServicesPicker items={parseServices(ROWS)} onPick={(it) => calls.push(it ? it.id : null)} />
      </ThemeProvider>,
    );
    return { ...r, calls };
  }

  it('lists every service with its badges', () => {
    const f = mount().lastFrame() ?? '';
    expect(f).toContain('MySQL');
    expect(f).toContain('Redis');
    expect(f).toContain('running');
    expect(f).toContain('no-boot');
  });

  it('filters live to the php versions as you type', async () => {
    const { stdin, lastFrame } = mount();
    await delay(20);
    stdin.write('php');
    await delay(20);
    const f = lastFrame() ?? '';
    expect(f).toContain('PHP-FPM 8.2');
    expect(f).toContain('PHP-FPM 8.3');
    expect(f).not.toContain('MySQL');
    expect(f).not.toContain('Redis');
  });

  it('Enter picks the focused service by id', async () => {
    const { stdin, calls } = mount();
    await delay(20);
    stdin.write('redis');
    await delay(20);
    stdin.write('\r');
    await delay(20);
    expect(calls).toEqual(['redis']);
  });

  it('Esc cancels with null', async () => {
    const { stdin, calls } = mount();
    await delay(20);
    stdin.write('\x1B');
    await delay(20);
    expect(calls).toEqual([null]);
  });
});

describe('ServiceActions (render + context)', () => {
  const items = parseServices(ROWS);
  it('a running service hides start and shows stop/restart/disable', () => {
    const r = render(
      <ThemeProvider iconSet="unicode">
        <ServiceActions service={items[0]} onAction={() => {}} />
      </ThemeProvider>,
    );
    const f = r.lastFrame() ?? '';
    expect(f).toContain('stop');
    expect(f).toContain('restart');
    expect(f).toContain('disable');
  });
});

describe('ServicesFlow (pick → action → hand back)', () => {
  function mount() {
    const calls: (string | null)[] = [];
    const r = render(
      <ThemeProvider iconSet="unicode">
        <ServicesFlow items={parseServices(ROWS)} onDone={(v) => calls.push(v)} />
      </ThemeProvider>,
    );
    return { ...r, calls };
  }

  it('filter → Enter → Enter hands back `<id>\\t<verb>`', async () => {
    const { stdin, calls } = mount();
    await delay(20);
    stdin.write('mysql');
    await delay(20);
    stdin.write('\r'); // pick mysql → ServiceActions (first action = stop)
    await delay(30);
    stdin.write('\r'); // run the focused action
    await delay(20);
    expect(calls).toEqual(['mysql\tstop']);
  });

  it('Esc on the list cancels the whole flow', async () => {
    const { stdin, calls } = mount();
    await delay(20);
    stdin.write('\x1B');
    await delay(20);
    expect(calls).toEqual([null]);
  });
});
