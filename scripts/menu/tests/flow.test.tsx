import { describe, it, expect, beforeAll } from 'vitest';
import { render } from 'ink-testing-library';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
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
    // personal/repo is `required` → seed it so the apply-time gate doesn't divert
    // to the identity onboarding; this test exercises the updates→summary→apply
    // path (the divert path has its own test below).
    mkdirSync(path.join(cfg, 'mesh'), { recursive: true });
    writeFileSync(path.join(cfg, 'mesh', 'params.env'), 'MESH_IDENTITY_REPO=git@github.com:test/mesh-identity.git\n');

    let code = -1;
    const { stdin, lastFrame, unmount } = renderApp((c) => (code = c));
    await delay(80);
    expect(lastFrame()).toContain('dev root'); // devroot is the first screen
    stdin.write('/srv/devroot'); // type an absolute dev root
    await delay(20);
    stdin.write('\r'); // save → picker (CODE_DIR resolved into params)
    await delay(20);
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
    expect(params).toContain('CODE_DIR=/srv/devroot'); // dev-root screen → params.env
    unmount();
  });

  it('required personal/repo unresolved → c diverts to identity onboarding, then applies', async () => {
    const cfg = tmp();
    const home = tmp(); // empty HOME → personal/repo default_from (git -C $HOME/mesh-identity) is empty
    const origHome = process.env.HOME;
    process.env.XDG_CONFIG_HOME = cfg;
    process.env.HOME = home;
    process.env.MESH_PLATFORM = 'mac';
    try {
      let code = -1;
      const { stdin, lastFrame, unmount } = renderApp((c) => (code = c));
      await delay(80);
      stdin.write('\x1B'); // skip dev root → picker
      await delay(20);
      stdin.write('c'); // try to apply — gate must divert (personal/repo required + empty)
      await delay(40);
      expect(lastFrame()).toContain('identity');
      expect(lastFrame()).toContain('Do you already have');
      stdin.write('\r'); // pick "adopt"
      await delay(20);
      stdin.write('git@github.com:me/mesh-identity.git');
      await delay(20);
      stdin.write('\r'); // save → back to picker
      await delay(20);
      stdin.write('c'); // now resolved → summary
      await delay(20);
      expect(lastFrame()).toContain('apply plan');
      stdin.write('y'); // apply
      await delay(80);
      expect(code).toBe(0);
      const params = readFileSync(path.join(cfg, 'mesh', 'params.env'), 'utf8');
      expect(params).toContain('MESH_IDENTITY_REPO=git@github.com:me/mesh-identity.git');
      unmount();
    } finally {
      if (origHome === undefined) delete process.env.HOME;
      else process.env.HOME = origHome;
    }
  });

  it('quit cancels with EXIT_CANCEL (130) so setup.sh aborts instead of applying defaults', async () => {
    const cfg = tmp();
    process.env.XDG_CONFIG_HOME = cfg;
    process.env.MESH_PLATFORM = 'mac';
    let code = -1;
    const { stdin, unmount } = renderApp((c) => (code = c));
    await delay(80);
    stdin.write('\x1B'); // skip dev root → picker (q would type into the path field)
    await delay(20);
    stdin.write('q');
    await delay(40);
    expect(code).toBe(130);
    unmount();
  });
});
