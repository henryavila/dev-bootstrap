/**
 * ai-pick-main — the `node index.js ai-pick …` entry: render the SearchPicker
 * over the runner's candidate set and hand the chosen row back to bash. Same
 * file-based contract as prompt-main (Ink draws on stdout, so the value goes to
 * --out, never stdout). Exit codes:
 *   0   = `<action>\t<chosen raw line>` written to --out (action ∈ open|new:
 *         Enter→open focuses/opens, Ctrl-N→new opens another agent in the repo)
 *   130 = user cancelled (Esc)        → runner opens nothing
 *   1   = bad args / no TTY / empty   → runner falls back to its bash picker
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { render } from 'ink';
import { ThemeProvider, detectIconSet } from '@henryavila/blink-tui';
import { registerDomainGlyphs } from './glyphs.js';
import { SearchPicker, parseCandidates, type AiAction } from './screens/SearchPicker.js';

export interface AiPickArgs {
  in: string;
  out: string;
}

/** Parse the ai-pick argv (everything AFTER the subcommand). Pure. Returns null
 *  when --in or --out is missing. */
export function parseAiPickArgs(argv: string[]): AiPickArgs | null {
  const get = (flag: string): string | undefined => {
    const i = argv.indexOf(flag);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : undefined;
  };
  const inPath = get('--in');
  const out = get('--out');
  if (!inPath || !out) return null;
  return { in: inPath, out };
}

export async function aiPickMain(args: string[]): Promise<void> {
  const opts = parseAiPickArgs(args);
  if (!opts) {
    process.stderr.write('mesh ai-pick: usage: ai-pick --in <candidates> --out <file>\n');
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
  let resultAction: AiAction = 'open';
  let unmountFn: (() => void) | undefined;
  const finish = (raw: string | null, action: AiAction = 'open') => {
    result = raw;
    resultAction = action;
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
  writeFileSync(opts.out, `${resultAction}\t${result}`);
  process.exit(0);
}
