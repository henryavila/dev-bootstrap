/**
 * app.tsx — bootstrap entry for the mesh setup wizard (loaded by index.js via
 * tsx). Detects the icon set, registers the domain glyph packs, renders <App/>,
 * and exits with the App's code:
 *   0   = wrote selections + applied (setup.sh proceeds with them)
 *   130 = user left without applying (quit / Ctrl-C) → setup.sh ABORTS
 *   1   = could not launch (no TTY) → setup.sh falls back to saved/default
 * The default is EXIT_CANCEL, so a crash/Ctrl-C mid-render aborts rather than
 * silently installing defaults the user never chose. The App component lives in
 * wizard.tsx so it stays side-effect-free and testable.
 */
import { render, useApp } from 'ink';
import { ThemeProvider, detectIconSet } from '@henryavila/blink-tui';
import { registerDomainGlyphs } from './glyphs.js';
import { App, EXIT_CANCEL } from './wizard.js';
import { MeshHelpScreen, parseHelpExtensionCommands } from './screens/MeshHelpScreen.js';

function requireInteractive(label: string) {
  if (process.stdin.isTTY) return;
  process.stderr.write(
    `${label}: needs an interactive terminal (no TTY on stdin).\n` +
      'Run it directly in your terminal.\n',
  );
  process.exit(1);
}

function StandaloneHelp({ onExit }: { onExit: (code: number) => void }) {
  const ink = useApp();
  return (
    <MeshHelpScreen
      extensionCommands={parseHelpExtensionCommands(process.env.MESH_HELP_EXTENSION_COMMANDS)}
      onClose={() => {
        onExit(0);
        ink.exit();
      }}
    />
  );
}

async function renderStandaloneHelp() {
  requireInteractive('mesh help');
  registerDomainGlyphs();
  const iconSet = await detectIconSet();

  let code = 0;
  const { waitUntilExit } = render(
    <ThemeProvider iconSet={iconSet}>
      <StandaloneHelp onExit={(c) => (code = c)} />
    </ThemeProvider>,
  );
  await waitUntilExit();
  process.exit(code);
}

async function main() {
  // `prompt` subcommand → a single-field blink-tui input for bash (the secret
  // key, init fields, confirmations) — the SAME engine as the wizard, not a
  // bare `read`. Loaded dynamically so the wizard path is untouched.
  const argv = process.argv.slice(2);
  if (argv[0] === 'prompt') {
    const { promptMain } = await import('./prompt-main.js');
    await promptMain(argv.slice(1));
    return;
  }

  // `ai-pick` subcommand → the realtime-filter project picker for `mesh ai`
  // (scripts/runners/ai.sh feeds candidates, reads the chosen line back).
  if (argv[0] === 'ai-pick') {
    const { aiPickMain } = await import('./ai-pick-main.js');
    await aiPickMain(argv.slice(1));
    return;
  }

  // `services` subcommand → the interactive `mesh services` flow (filter list →
  // context-aware action). scripts/runners/services.sh feeds porcelain rows and
  // reads `<id>\t<verb>` back, then dispatches the driver.
  if (argv[0] === 'services') {
    const { servicesMain } = await import('./services-main.js');
    await servicesMain(argv.slice(1));
    return;
  }

  // `help` subcommand → open the standalone mesh command reference, without
  // first entering the setup flow.
  if (argv[0] === 'help') {
    await renderStandaloneHelp();
    return;
  }

  // The wizard is keyboard-interactive (Ink raw mode), which needs a real TTY.
  // Without one (piped stdin, CI, or a non-interactive `!`-style shell) Ink's
  // useInput would throw a raw-mode stack trace, so fail clearly instead and let
  // the caller fall back to the saved/default selection.
  requireInteractive('mesh menu');

  registerDomainGlyphs();
  const dryRun = process.argv.slice(2).includes('--dry-run');
  const iconSet = await detectIconSet();

  let code = EXIT_CANCEL;
  const { waitUntilExit } = render(
    <ThemeProvider iconSet={iconSet}>
      <App dryRun={dryRun} onExit={(c) => (code = c)} />
    </ThemeProvider>,
  );
  await waitUntilExit();
  process.exit(code);
}

main();
