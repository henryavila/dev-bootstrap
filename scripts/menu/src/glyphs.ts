/**
 * glyphs.ts — opt into the blink-tui domain glyph packs the manifests reference.
 *
 * BLINK-ONLY RULE (feedback_mesh_ink_app_blink_only): we register blink's own
 * curated packs via its public registerGlyphs() API and invent NOTHING. Manifest
 * `icon_name`s that blink ships render their glyph; the two synonyms below alias
 * onto an existing blink glyph; anything blink lacks resolves to `undefined`
 * (the List/ProgressList `domain` column is optional → graceful no-glyph).
 *
 * The five packs below cover every icon_name used across the 12 manifests. The
 * SYSTEM pack + the `claude` glyph (in COMPANIES) were the 12-name gap that was
 * reported to — and added upstream in — blink (terminal, code, globe, home,
 * key, mail, phone, package, sync, text, tools, claude). The
 * `manifest icon coverage` test guards that none regresses to a no-glyph.
 */
import {
  registerGlyphs,
  hasGlyph,
  COMMON_DOMAINS,
  CLOUD,
  FRAMEWORKS,
  FILES,
  SYSTEM,
  COMPANIES,
} from '@henryavila/blink-tui';

let registered = false;

/** Register the blink packs that cover the manifests' icon_names. Idempotent. */
export function registerDomainGlyphs(): void {
  if (registered) return;
  registerGlyphs(COMMON_DOMAINS); // database, docker, git, github, mysql, php, postgresql, redis, ssh, nodejs, vim …
  registerGlyphs(CLOUD); // nginx …
  registerGlyphs(FRAMEWORKS); // laravel …
  registerGlyphs(FILES); // lock …
  registerGlyphs(SYSTEM); // terminal, code, globe, home, key, mail, phone, package, sync, text, tools
  registerGlyphs(COMPANIES); // claude (+ github, …)
  registered = true;
}

/** Manifest icon_name synonyms → an existing blink glyph name. */
const ALIAS: Record<string, string> = {
  node: 'nodejs',
  postgres: 'postgresql',
};

/**
 * Resolve a manifest `icon_name` to a registered blink glyph name, or undefined
 * when blink has no glyph for it (caller omits the `domain` column).
 */
export function resolveDomain(iconName?: string): string | undefined {
  if (!iconName) return undefined;
  const name = ALIAS[iconName] ?? iconName;
  return hasGlyph(name) ? name : undefined;
}
