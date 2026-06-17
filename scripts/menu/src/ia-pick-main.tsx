/**
 * ia-pick-main — the `node index.js ia-pick …` entry: render the SearchPicker
 * over the runner's candidate set and hand the chosen row back to bash. Same
 * file-based contract as prompt-main (Ink draws on stdout, so the value goes to
 * --out, never stdout). Exit codes:
 *   0   = chosen raw line written to --out
 *   130 = user cancelled (Esc)        → runner opens nothing
 *   1   = bad args / no TTY / empty   → runner falls back to its bash picker
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { render } from 'ink';
import { ThemeProvider, detectIconSet } from '@henryavila/blink-tui';
import { registerDomainGlyphs } from './glyphs.js';
import { SearchPicker, parseCandidates } from './screens/SearchPicker.js';

export interface IaPickArgs {
  in: string;
  out: string;
}

/** Parse the ia-pick argv (everything AFTER the subcommand). Pure. Returns null
 *  when --in or --out is missing. */
export function parseIaPickArgs(argv: string[]): IaPickArgs | null {
  const get = (flag: string): string | undefined => {
    const i = argv.indexOf(flag);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : undefined;
  };
  const inPath = get('--in');
  const out = get('--out');
  if (!inPath || !out) return null;
  return { in: inPath, out };
}

export async function iaPickMain(args: string[]): Promise<void> {
  const opts = parseIaPickArgs(args);
  if (!opts) {
    process.stderr.write('mesh ia-pick: usage: ia-pick --in <candidates> --out <file>\n');
    process.exit(1);
  }

  // Raw-mode keyboard input needs a real TTY; without one, exit 1 so the runner
  // falls back to its bash picker instead of crashing.
  if (!process.stdin.isTTY) process.exit(1);

  let text = '';
  try {
    text = readFileSync(opts.in, 'utf8');
  } catch {
    process.exit(1);
  }
  const items = parseCandidates(text);
  if (items.length === 0) process.exit(1);

  registerDomainGlyphs();
  const iconSet = await detectIconSet();

  let result: string | null = null;
  let unmountFn: (() => void) | undefined;
  const finish = (raw: string | null) => {
    result = raw;
    unmountFn?.();
  };

  const { waitUntilExit, unmount } = render(
    <ThemeProvider iconSet={iconSet}>
      <SearchPicker items={items} onDone={finish} />
    </ThemeProvider>,
  );
  unmountFn = unmount;
  await waitUntilExit();

  if (result === null) process.exit(130); // cancelled
  writeFileSync(opts.out, result);
  process.exit(0);
}
