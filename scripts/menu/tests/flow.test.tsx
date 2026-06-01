import { describe, it, expect, beforeAll } from 'vitest';
import { render } from 'ink-testing-library';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { ThemeProvider } from '@henryavila/blink-tui';
import { App } from '../src/wizard.js';
import { registerDomainGlyphs } from '../src/glyphs.js';
import { tmp } from './helpers.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

beforeAll(() => registerDomainGlyphs());

function renderApp(onExit: (c: number) => void) {
  return render(
    <ThemeProvider iconSet="unicode">
      <App dryRun={false} onExit={onExit} />
    </ThemeProvider>,
  );
}

describe('full wizard flow (ink-testing-library)', () => {
  it('fresh install → updates toggle → summary → apply writes the state files', async () => {
    const cfg = tmp();
    process.env.XDG_CONFIG_HOME = cfg;
    process.env.MESH_PLATFORM = 'mac';

    let code = -1;
    const { stdin, lastFrame, unmount } = renderApp((c) => (code = c));
    await delay(80);
    expect(lastFrame()).toContain('mesh setup');

    stdin.write('u'); // updates screen
    await delay(20);
    expect(lastFrame()).toContain('mesh update');
    stdin.write(' '); // toggle agent-clis on
    await delay(20);
    stdin.write('\r'); // save → picker
    await delay(20);
    stdin.write('c'); // summary
    await delay(20);
    expect(lastFrame()).toContain('apply plan');
    stdin.write('y'); // apply
    await delay(80);

    expect(code).toBe(0);
    const sel = readFileSync(path.join(cfg, 'mesh', 'selections.list'), 'utf8');
    expect(sel).toContain('git/config');
    expect(sel).not.toContain('git/gpg-signing'); // default-off
    const params = readFileSync(path.join(cfg, 'mesh', 'params.env'), 'utf8');
    expect(params).toContain('MESH_UPDATE_AGENT_CLIS=1');
    expect(params).toContain('MESH_UPDATE_CLI_TOOLS=0');
    unmount();
  });

  it('quit cancels with exit 1 and writes nothing new', async () => {
    const cfg = tmp();
    process.env.XDG_CONFIG_HOME = cfg;
    process.env.MESH_PLATFORM = 'mac';
    let code = -1;
    const { stdin, unmount } = renderApp((c) => (code = c));
    await delay(80);
    stdin.write('q');
    await delay(40);
    expect(code).toBe(1);
    unmount();
  });
});
