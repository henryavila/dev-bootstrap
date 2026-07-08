/**
 * services-main — the `node index.js services …` entry: render the two-screen
 * `mesh services` flow (filter list → context-aware action) and hand
 * `<service-id><TAB><verb>` back to bash. Same file-based contract as
 * ai-pick-main (Ink draws on /dev/tty, so the value goes to --out, never
 * stdout). Exit codes:
 *   0   = `<id>\t<verb>` written to --out
 *   130 = user cancelled (Esc on the list)
 *   1   = bad args / no TTY / empty   → runner falls back to its bash picker
 */
import { useState } from 'react';
import { readFileSync, writeFileSync } from 'node:fs';
import { render } from 'ink';
import { ThemeProvider, detectIconSet } from '@henryavila/blink-tui';
import { registerDomainGlyphs } from './glyphs.js';
import { ServicesPicker, parseServices, type ServiceItem } from './screens/ServicesPicker.js';
import { ServiceActions } from './screens/ServiceActions.js';

export interface ServicesArgs {
  in: string;
  out: string;
}

/** Parse the services argv (everything AFTER the subcommand). Pure. Returns null
 *  when --in or --out is missing. */
export function parseServicesArgs(argv: string[]): ServicesArgs | null {
  const get = (flag: string): string | undefined => {
    const i = argv.indexOf(flag);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : undefined;
  };
  const inPath = get('--in');
  const out = get('--out');
  if (!inPath || !out) return null;
  return { in: inPath, out };
}

/** Two-screen orchestrator: pick a service, then a context-aware action. Esc on
 *  the list cancels (null → caller opens nothing); Esc on the actions goes back
 *  to the list. Exposed for tests. */
export function ServicesFlow({
  items,
  onDone,
}: {
  items: ServiceItem[];
  onDone: (result: string | null) => void;
}) {
  const [picked, setPicked] = useState<ServiceItem | null>(null);
  if (!picked) {
    return <ServicesPicker items={items} onPick={(it) => (it ? setPicked(it) : onDone(null))} />;
  }
  return (
    <ServiceActions
      service={picked}
      onAction={(verb) => (verb ? onDone(`${picked.id}\t${verb}`) : setPicked(null))}
    />
  );
}

export async function servicesMain(args: string[]): Promise<void> {
  const opts = parseServicesArgs(args);
  if (!opts) {
    process.stderr.write('mesh services: usage: services --in <rows> --out <file>\n');
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
  const items = parseServices(text);
  if (items.length === 0) process.exit(1);

  registerDomainGlyphs();
  const iconSet = await detectIconSet();

  let result: string | null = null;
  let unmountFn: (() => void) | undefined;
  const finish = (r: string | null) => {
    result = r;
    unmountFn?.();
  };

  const { waitUntilExit, unmount } = render(
    <ThemeProvider iconSet={iconSet}>
      <ServicesFlow items={items} onDone={finish} />
    </ThemeProvider>,
  );
  unmountFn = unmount;
  await waitUntilExit();

  if (result === null) process.exit(130); // cancelled
  writeFileSync(opts.out, result);
  process.exit(0);
}
