/**
 * prompt-main — the `node index.js prompt …` entry: render ONE PromptScreen and
 * hand the value back to bash. Output goes to a FILE (--out), never stdout,
 * because Ink draws on stdout — the same file-based contract the wizard uses for
 * params.env. Exit codes mirror the wizard's:
 *   0   = value written to --out
 *   130 = user cancelled (Esc)        → bash treats as empty/no
 *   1   = bad args / no TTY           → bash falls back to its own `read`
 */
import { writeFileSync } from 'node:fs';
import { render } from 'ink';
import { ThemeProvider, detectIconSet } from '@henryavila/blink-tui';
import { registerDomainGlyphs } from './glyphs.js';
import { PromptScreen, parsePromptArgs, type PromptType } from './screens/PromptScreen.js';
import { PauseScreen } from './screens/PauseScreen.js';

export async function promptMain(args: string[]): Promise<void> {
  const opts = parsePromptArgs(args);
  if (!opts) {
    process.stderr.write('mesh prompt: usage: prompt --type text|secret|confirm --label … --out <file> [--default …]\n');
    process.exit(1);
  }

  // Keyboard-interactive (Ink raw mode) needs a real TTY. Without one, exit 1 so
  // the bash caller falls back to its own read instead of crashing on raw mode.
  if (!process.stdin.isTTY) process.exit(1);

  registerDomainGlyphs();
  const iconSet = await detectIconSet();

  let result: string | null = null;
  let unmountFn: (() => void) | undefined;
  // Set the value then tear down the render — unmountFn is assigned right after
  // render() below, before any keypress can fire onDone.
  const finish = (v: string | null) => {
    result = v;
    unmountFn?.();
  };

  const screen =
    opts.type === 'pause' ? (
      // Acknowledge (Enter to continue) — a Dialog, not a field. Empty string on
      // continue; null on skip (Esc).
      <PauseScreen label={opts.label} onDone={(ok) => finish(ok ? '' : null)} />
    ) : (
      <PromptScreen
        type={opts.type as PromptType}
        label={opts.label}
        defaultValue={opts.default}
        choices={opts.choices}
        onDone={(v) => finish(v)}
      />
    );

  const { waitUntilExit, unmount } = render(
    <ThemeProvider iconSet={iconSet}>{screen}</ThemeProvider>,
  );
  unmountFn = unmount;
  await waitUntilExit();

  if (result === null) process.exit(130); // cancelled
  writeFileSync(opts.out, result);
  process.exit(0);
}
