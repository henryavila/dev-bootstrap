/**
 * app.tsx — bootstrap entry for the mesh setup wizard (loaded by index.js via
 * tsx). Detects the icon set, registers the domain glyph packs, renders <App/>,
 * and exits with the App's code (0 = wrote selections + applied; 1 = cancelled,
 * caller falls back to saved/default). The App component lives in wizard.tsx so
 * it stays side-effect-free and testable.
 */
import { render } from 'ink';
import { ThemeProvider, detectIconSet } from '@henryavila/blink-tui';
import { registerDomainGlyphs } from './glyphs.js';
import { App } from './wizard.js';

async function main() {
  // The wizard is keyboard-interactive (Ink raw mode), which needs a real TTY.
  // Without one (piped stdin, CI, or a non-interactive `!`-style shell) Ink's
  // useInput would throw a raw-mode stack trace, so fail clearly instead and let
  // the caller fall back to the saved/default selection.
  if (!process.stdin.isTTY) {
    process.stderr.write(
      'mesh menu: needs an interactive terminal (no TTY on stdin).\n' +
        'Run it directly in your terminal, e.g.\n' +
        '  node scripts/menu/index.js\n' +
        'or use the non-interactive flow: NON_INTERACTIVE=1 bash setup.sh\n',
    );
    process.exit(1);
  }

  registerDomainGlyphs();
  const dryRun = process.argv.slice(2).includes('--dry-run');
  const iconSet = await detectIconSet();

  let code = 1;
  const { waitUntilExit } = render(
    <ThemeProvider iconSet={iconSet}>
      <App dryRun={dryRun} onExit={(c) => (code = c)} />
    </ThemeProvider>,
  );
  await waitUntilExit();
  process.exit(code);
}

main();
