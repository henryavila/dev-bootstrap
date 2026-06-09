# Claude Design — prompt: `TopicPicker` screen (mesh setup wizard on blink)

> **How to use.** Paste the **PROMPT** block below as the *first message* in a new
> Claude Design conversation (claude.ai/design). Attach
> `CaskaydiaMonoNerdFontMono-Regular.woff2` first (for the HTML preview font;
> source: nerd-fonts releases → CascadiaMono.zip → `woff2_compress`).
> Claude replies `Primed.` and then designs the screen, proposing **new blink
> primitives** where the screen needs something the library lacks.
>
> **Why this exists / what changed since the last prompt.** The earlier template
> (`2026-05-28-modern-tui-claude-design-prompt.md`) predated the library: it told
> the designer to hand-roll Box helpers in raw Ink. That library now exists and
> is real — **`@henryavila/blink-tui`** (github.com/henryavila/blink-tui, 61
> tests green). This prompt targets that concrete API. The designer composes
> blink primitives; when the TopicPicker needs a primitive blink doesn't have, it
> proposes one **generically** (per blink's prime directive — the wizard is one
> consumer, never the design target).
>
> **Context for the human:** F9.6 task T-304. The screen reads Manifest 2.0
> (`docs/2026-05-28-mesh-manifest-v2-spec.md`). Fixtures below are the typed shape
> `manifest-reader.ts` (T-301) emits + the per-bundle state `scanner.ts` (T-302)
> resolves.

---

## PROMPT (copy from here ↓)

````
You are designing one screen of a terminal UI (TUI) built on **blink**
(`@henryavila/blink-tui`) — a thin, opinionated layer over Ink (React for the
terminal). Your job: design the **TopicPicker** screen described below, and
output it as (A) an HTML/Tailwind mockup that simulates the terminal in the
Claude Design preview, and (B) the equivalent Ink JSX that imports blink
primitives and ships to production. If the screen needs a UI capability blink
does not yet have, propose it as a NEW GENERIC blink primitive in a separate
section (see OUTPUT).

═══════════════════════════════════════════════════════════════════
1 · blink — the framework you compose with
═══════════════════════════════════════════════════════════════════

blink gives every app one house style on a strict character-cell grid:
Catppuccin Mocha theming, dual-mode Nerd Font glyphs, box-drawing panes,
keyboard-only interaction. Rule of thumb: *if you can't draw it with
characters, it doesn't belong in a blink app.*

COMPONENTS (import from '@henryavila/blink-tui'):
- Pane         box-drawn rectangle, title inside the top border; `focused`
               recolours the border lavender + makes it double-line; `variant`
               = default | double | rounded | error.
- List/ListRow rows with a `▸` focus caret, a state glyph + optional domain
               glyph, a right-aligned `meta`, and a selection fill. Pass
               `height` to window a long list (keyboard-paged; shows `▴ N more`
               / `▾ N more`). Props: { rows, focusedId, selectedIds, height,
               overflowMarkers }. ListRowData: { id, glyph?, glyphColor?,
               domainGlyph?, label, meta?, dim? }.
- Footer       always-visible bottom hotkey bar: inverse-video key chips +
               a right status slot. Props: { keys: {k,desc}[], right }.
- Banner       one-line, non-blocking, in-flow notice. tone = info|warn|success,
               optional leading glyph. Use for "auto-selected …" notices.
- Dialog       centred double-border modal. Plain `lines: string[]` OR a rich
               `children` body. `actions[]` — the primary renders inverse-accent.
               Use for the dependent-removal confirm.
- LogView      bottom-anchored, height-bounded tail of a growing line stream
               (subprocess output). { lines, height, follow?, wrap? }. (Used by
               a later screen, ApplyProgress — not this one; listed for context.)
- Spinner      braille spinner (ascii fallback), driven by useSpinnerFrame.
- ProgressBar  determinate bar from the eighth-block ramp. { value 0..1, width }.
- Input/Cursor single-line presentational field (app owns keys).

HEADLESS HOOKS (blink owns the logic; the app owns the keys — it calls these
from its OWN Ink `useInput`. No blink component reads keystrokes):
- useListNavigation({ ids, ... }) → focus movement (next/prev/first/last/seek).
- useListSelection({ ids, mode:'single'|'multi', min?, max? }) → selection set,
  toggle, min/max guards; feeds List `selectedIds`.
- useListWindow({ rowCount, focusedIndex, height, ... }) → the windowing engine
  behind List `height` (reuse for any keyboard-paged viewport).
- useStdoutDimensions() → live { columns, rows } (switch 100×30 ↔ 60×20).
- useBlink(), useSpinnerFrame() → the only sanctioned motion.

THEME + GLYPHS:
- useTokens() → semantic tokens; NEVER raw hex in components. Tokens you'll use:
  fg, fgMuted, fgDim, accent (lavender), accentAlt (pink), stateOk (green),
  stateWarn (yellow), stateErr (red), stateInfo (sapphire), bgFocus (surface0).
- useGlyph() → (name) ⇒ string, bound to the detected icon set. Built-in names:
  states  check cross circle half checkboxOn checkboxOff warn rerun
  nav     focus collapsed expanded depends flow back moreAbove moreBelow
  domains database mysql postgresql redis docker github git ssh nodejs php
          python vim apple linux ubuntu font ai bolt
  Need a domain glyph not in this list (e.g. laravel, tailscale, syncthing,
  catppuccin)? Do NOT invent it inline — call it out in OUTPUT §"glyph requests"
  so it's added to blink's registry deliberately with {nerd,unicode,ascii}.

═══════════════════════════════════════════════════════════════════
2 · the visual + interaction contract (non-negotiable)
═══════════════════════════════════════════════════════════════════

- One family, one size, one weight: CaskaydiaMono NF, 14px, 400. "Bold" =
  INVERSE VIDEO, never 700.
- Catppuccin Mocha, always. Background `base` #1e1e2e — no gradient/image/blur.
  Three text tiers (fg/fgMuted/fgDim); past that reach for an accent, never a
  4th grey. Semantic colour lives on GLYPHS, not body text (green is the `✓`,
  not the word "ok").
- Every border is a box-drawing glyph via Pane. No CSS border/radius/outline.
  Single line default; DOUBLE line = focused pane or modal. Elevation is border
  WEIGHT, never shadow.
- Flexbox only (Box flexDirection row|column, nested). No absolute/z-index.
- Keyboard only. No mouse, scrollbar, wheel, hover. Focus is character-based:
  the `▸` caret, a surface fill, or a recoloured (lavender) border. A list
  longer than its pane is keyboard-paged (List height) with `▴/▾ N more`.
- One animation: the 1 Hz cursor blink + an optional spinner. Nothing else
  MOVES. (A windowed list following focus / a LogView following its tail is
  content redraw, not motion.)
- No emoji, no SVG, no raster. Status = palette glyphs (✓ ✗ ◯ ◐ ⚠ ↻).

COPY VOICE: terse, lowercase, command-shaped. Second-person imperative. No
exclamation marks. "state, then action" (`3 changes  ↳ press a to apply`).
UPPER CASE only for KEY indicators.

LAYOUT TARGET: 100 cols × 30 rows primary; 60 cols × 20 rows mobile-mosh
fallback. The design must read at BOTH — show the fallback (panes stack
vertically; detail collapses to a single line) in artifact (A) as a second
frame.

═══════════════════════════════════════════════════════════════════
3 · the app + its data model (Manifest 2.0)
═══════════════════════════════════════════════════════════════════

The app is the **mesh setup wizard** — a keyboard-driven installer run over
ssh/mosh that configures a dev machine. The catalog is a hierarchy:

  TOPIC  (e.g. "Web", "Databases")
    └── BUNDLE  (the unit the USER selects, e.g. "Valet", "MySQL") — atomic
          ├── items[]    (install actions the engine runs; user never toggles
          │               these individually — the bundle is the unit)
          └── options[]  (user-configurable params: PHP versions, git name,
                          ngrok token — edited on a SEPARATE screen, not here)

Rules that shape THIS screen:
- A topic can be `required` (always-on, e.g. Identity, Git) — it still shows in
  the tree but its bundles can't be deselected; or opt-in. (One topic,
  "Foundation", is `required` AND invisible — it never appears.)
- A bundle has a SCANNER STATE (is it installed on this host right now?):
    installed   ✓ stateOk     — present & current
    missing     ✗ stateErr    — not installed
    drift       ◐ stateWarn   — installed but config out of date
    partial     ◐ stateWarn   — some items present, some missing
    idempotent  ↻ fgMuted     — always re-runs, no meaningful "installed" state
- A bundle has a SELECTION STATE (does the user want it?): ☑ selected / ☐ not.
  On a FRESH install most opt-in bundles default selected; `code-server` and
  `gpg-signing` default OFF. On a RE-RUN, prior selections are loaded.
- The delta the user is building: for each bundle, selected + missing ⇒ INSTALL;
  not-selected + installed ⇒ REMOVE; selected + installed ⇒ KEEP.
- `requires_bundles` cross-topic deps: selecting `web/valet` auto-selects
  `databases/mysql` + `databases/redis` (show a Banner). Trying to deselect a
  bundle that a still-selected bundle requires ⇒ Dialog: keep it, or also
  deselect the dependent.

═══════════════════════════════════════════════════════════════════
4 · THE SCREEN — TopicPicker
═══════════════════════════════════════════════════════════════════

A 3-pane hierarchical browser. The spine of the whole wizard.

  ┌ header (1 row) ────────────────────────────────────────────────┐
  │ ▎ mesh setup · <host> (<os>)              <delta summary, right>│
  ├──────────────┬─────────────────────────────────────────────────┤
  │ TOPICS       │ BUNDLES of the focused topic                     │
  │ (left pane,  │ (top-right pane)                                 │
  │  ~30% width) ├─────────────────────────────────────────────────┤
  │              │ DETAIL of the focused bundle                     │
  │              │ (bottom-right pane)                              │
  ├──────────────┴─────────────────────────────────────────────────┤
  │ [banner — appears only when a dep was auto-selected]            │
  ├─────────────────────────────────────────────────────────────────┤
  │ footer hotkey bar                          right: delta counts  │
  └─────────────────────────────────────────────────────────────────┘

LEFT PANE — topics tree (a `List`):
  Each row: domain glyph (topic icon) + label + a right `meta` "k/n" =
  selected / total bundles in that topic. `required` topics get a dim `req`
  tag. The focused topic row carries the `▸` caret + surface fill. Selecting a
  topic row changes what the right panes show (it does NOT toggle anything —
  toggling happens at the bundle level).

TOP-RIGHT PANE — bundles of the focused topic (a `List`, windowed via height):
  Each row: a checkbox glyph (☑/☐) for selection + a state glyph
  (✓/✗/◐/↻ in the state colour) + the bundle label + a right `meta` that states
  the CONSEQUENCE in copy-voice — e.g. `→ install`, `→ remove`, `keep`,
  `↳ needs mysql, redis`, `req` (for a required bundle, no checkbox toggle).
  Required bundles render the checkbox as a filled, non-interactive marker.
  Platform-gated bundles not for this OS are simply absent (already filtered).

BOTTOM-RIGHT PANE — detail of the focused bundle:
  - label + one-line `desc`
  - `state` line: the glyph + word (installed / missing / drift …) + host note
  - `change` line: what Apply will do to it (install / remove / keep) in
    state-then-action voice
  - `items` count ("4 steps")
  - `requires` line if any: `↳ databases/mysql · databases/redis`
  - `options` summary if any: "2 options · press enter to configure"
    (the OptionsForm is a different screen; here just surface that they exist)

BANNER (transient, between panes and footer; omit when nothing to say):
  success/info tone, e.g.
  `↳ auto-selected databases/mysql, databases/redis — required by web/valet`

FOOTER hotkeys (left→right) + right status:
  space toggle · enter options · tab pane · a all · n none · / search · ? help
  · q quit          right: `✓ 6 install · ✗ 1 remove · 9 keep`
  Plus a clear way to ADVANCE to the summary/confirm step — propose the
  affordance (a key chip, e.g. `↵ done` on a focused "continue", or a dedicated
  key). Call out your choice; don't overload `enter` (which opens options).

KEYS the app wires (via Ink useInput, feeding blink's headless hooks):
  ↑↓ / j k  move focus within the focused pane
  tab       switch focused pane (topics ↔ bundles)
  space     toggle the focused bundle's selection (no-op on required)
  enter     open the focused bundle's OptionsForm (if it has options)
  a / n     select all / none within the focused topic
  /         filter (search label + desc) — uses Input
  ?         help overlay (Dialog)
  q         quit

STATES the screen owns (for your component decomposition):
  focusedPane: 'topics' | 'bundles'
  focusedTopicId, focusedBundleId
  selectedBundleIds: Set   (use useListSelection mode:'multi')
  searchQuery: string | null
  pendingDialog: null | { kind:'dependent-removal', bundle, dependents[] }

DESIGN DECISIONS I want you to make (and note your rationale):
  - Topics tree: flat List, or does it want a real TREE primitive (topic →
    expandable bundle children inline) instead of master-detail? Recommend one.
    If a generic `Tree`/`TreeSelect` primitive is warranted, propose it (§OUTPUT).
  - The detail pane is a key/value-ish block. Is a generic `DescriptionList` /
    `KeyValue` primitive worth adding to blink, or is it just Text rows? Decide.
  - The header (mark + title + right status) recurs across every wizard screen —
    is it a generic `Header`/`StatusBar` primitive? Propose if so.
  - How the selection checkbox + state glyph coexist on one List row without
    clutter at 60 cols.

═══════════════════════════════════════════════════════════════════
5 · FIXTURES — concrete data to lay the screen out against
═══════════════════════════════════════════════════════════════════

This is the typed shape `manifest-reader.ts` produces, already merged with
`scanner.ts` state, for a RE-RUN on a mac host (`code-server`, macOS) where the
web+php stack is already installed. Design against THIS data — real labels,
real states, real deps.

```ts
type ScanState = 'installed' | 'missing' | 'drift' | 'partial' | 'idempotent';

interface Option { name: string; type: 'multiselect'|'select'|'toggle'|'text'|'secret'; label: string; }
interface Bundle {
  topic: string; name: string; label: string; desc: string;
  platforms: string[];           // current host is 'mac'
  required: boolean;
  defaultSelected: boolean;
  requiresBundles: string[];     // "topic/bundle"
  iconName?: string;
  itemCount: number;
  options: Option[];
  state: ScanState;              // scanner result on THIS host
  selected: boolean;             // current selection (loaded from selections.list)
}
interface Topic {
  name: string; label: string; hint?: string;
  required: boolean; order: number;
  bundles: Bundle[];
}

const HOST = { name: 'code-server', os: 'mac' };

const TOPICS: Topic[] = [
  { name:'identity', label:'Identity', hint:'who you are to git + ssh', required:true, order:10, bundles:[
    { topic:'identity', name:'git-identity', label:'Git identity', desc:'name + email for every commit', platforms:['mac','wsl'], required:true, defaultSelected:true, requiresBundles:[], iconName:'git', itemCount:1, options:[{name:'name',type:'text',label:'Full name'},{name:'email',type:'text',label:'Email'}], state:'installed', selected:true },
    { topic:'identity', name:'ssh-keys', label:'SSH keys', desc:'ed25519 keypair + agent', platforms:['mac','wsl'], required:true, defaultSelected:true, requiresBundles:[], iconName:'ssh', itemCount:2, options:[], state:'installed', selected:true },
  ]},
  { name:'git', label:'Git', hint:'config, aliases, signing', required:true, order:30, bundles:[
    { topic:'git', name:'git-config', label:'Git config', desc:'aliases, pager, sane defaults', platforms:['mac','wsl'], required:true, defaultSelected:true, requiresBundles:[], iconName:'git', itemCount:3, options:[], state:'installed', selected:true },
    { topic:'git', name:'gpg-signing', label:'GPG signing', desc:'sign every commit + tag', platforms:['mac','wsl'], required:false, defaultSelected:false, requiresBundles:[], iconName:'git', itemCount:2, options:[{name:'key',type:'text',label:'Signing key id'}], state:'missing', selected:false },
  ]},
  { name:'languages', label:'Languages', hint:'php, node, python toolchains', required:false, order:50, bundles:[
    { topic:'languages', name:'php', label:'PHP', desc:'multi-version php via ondrej/brew', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'php', itemCount:6, options:[{name:'versions',type:'multiselect',label:'PHP versions'}], state:'installed', selected:true },
    { topic:'languages', name:'node', label:'Node', desc:'node lts + corepack + pnpm', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'nodejs', itemCount:3, options:[], state:'installed', selected:true },
    { topic:'languages', name:'python', label:'Python', desc:'pyenv + uv package manager', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'python', itemCount:3, options:[], state:'drift', selected:true },
  ]},
  { name:'databases', label:'Databases', hint:'mysql, postgres, redis', required:false, order:60, bundles:[
    { topic:'databases', name:'mysql', label:'MySQL', desc:'mysql 8 — local database server', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'mysql', itemCount:2, options:[], state:'installed', selected:true },
    { topic:'databases', name:'postgresql', label:'PostgreSQL', desc:'postgres — local database server', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'postgresql', itemCount:2, options:[], state:'missing', selected:false },
    { topic:'databases', name:'redis', label:'Redis', desc:'in-memory cache + queue backend', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'redis', itemCount:1, options:[], state:'installed', selected:true },
    { topic:'databases', name:'mssql-driver', label:'MS SQL driver', desc:'sqlsrv php ext + odbc (corporate)', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'database', itemCount:3, options:[], state:'missing', selected:false },
  ]},
  { name:'web', label:'Web', hint:'valet/nginx + mailpit + ngrok', required:false, order:70, bundles:[
    { topic:'web', name:'valet', label:'Valet', desc:'laravel valet — *.localhost https, zero config', platforms:['mac'], required:false, defaultSelected:true, requiresBundles:['databases/mysql','databases/redis'], iconName:'laravel', itemCount:4, options:[], state:'installed', selected:true },
    { topic:'web', name:'mailpit', label:'Mailpit', desc:'catch outgoing mail at :8025', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'database', itemCount:1, options:[], state:'missing', selected:true },
    { topic:'web', name:'ngrok', label:'ngrok', desc:'public https tunnel to a local port', platforms:['mac','wsl'], required:false, defaultSelected:false, requiresBundles:[], iconName:'bolt', itemCount:1, options:[{name:'authtoken',type:'secret',label:'ngrok authtoken'}], state:'missing', selected:false },
  ]},
  { name:'containers', label:'Containers', hint:'docker / colima', required:false, order:80, bundles:[
    { topic:'containers', name:'docker', label:'Docker', desc:'colima + docker cli on mac', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'docker', itemCount:3, options:[], state:'missing', selected:false },
  ]},
  { name:'remote-access', label:'Remote Access', hint:'tailscale, code-server, mosh', required:false, order:90, bundles:[
    { topic:'remote-access', name:'tailscale', label:'Tailscale', desc:'mesh vpn — reach every host by name', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'ssh', itemCount:2, options:[], state:'installed', selected:true },
    { topic:'remote-access', name:'code-server', label:'code-server', desc:'vs code in the browser over tailscale', platforms:['mac','wsl'], required:false, defaultSelected:false, requiresBundles:['remote-access/tailscale'], iconName:'nodejs', itemCount:4, options:[], state:'missing', selected:false },
    { topic:'remote-access', name:'mosh', label:'Mosh', desc:'roaming ssh that survives sleep', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'ssh', itemCount:1, options:[], state:'drift', selected:true },
  ]},
  { name:'syncthing', label:'Syncthing', hint:'p2p folder sync', required:false, order:100, bundles:[
    { topic:'syncthing', name:'syncthing', label:'Syncthing', desc:'sync ~/code across the mesh, no cloud', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'database', itemCount:2, options:[], state:'missing', selected:true },
  ]},
  { name:'ai', label:'AI', hint:'claude code + agent tools', required:false, order:110, bundles:[
    { topic:'ai', name:'claude-code', label:'Claude Code', desc:'anthropic cli + mcp wiring', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:[], iconName:'ai', itemCount:2, options:[], state:'installed', selected:true },
    { topic:'ai', name:'agent-tools', label:'Agent tools', desc:'mdprobe + atomic-skills + rtk', platforms:['mac','wsl'], required:false, defaultSelected:true, requiresBundles:['ai/claude-code'], iconName:'ai', itemCount:3, options:[], state:'partial', selected:true },
  ]},
  // (shell-terminal, dotfiles-personal omitted from fixture for brevity —
  //  both required topics, all bundles installed/selected)
];
```

Derived delta for the fixture above (compute + show this in the footer right
slot + per-row meta):
  INSTALL (selected & not installed): web/mailpit, syncthing/syncthing
  REMOVE  (installed & deselected):   — none in this fixture —
  KEEP    (selected & installed):     identity/*, git/git-config, languages/*,
                                      databases/mysql, databases/redis,
                                      web/valet, remote-access/tailscale,
                                      remote-access/mosh, ai/*
  ⇒ footer right: `✓ 2 install · ✗ 0 remove · 13 keep`

SCENARIO TO ILLUSTRATE (draw at least one frame mid-interaction):
focused pane = bundles, focused topic = "Databases", and the user just toggled
`web/valet` ON in a prior step — so the Banner reads
`↳ auto-selected databases/mysql, databases/redis — required by web/valet`.
Also draw the dependent-removal Dialog: user tries to deselect
`databases/mysql` while `web/valet` is still selected ⇒
  title: "mysql is required"
  body:  "web/valet needs databases/mysql. deselect valet too, or keep mysql?"
  actions: [ keep mysql (primary) ] [ also deselect valet ]

═══════════════════════════════════════════════════════════════════
6 · OUTPUT — what to produce
═══════════════════════════════════════════════════════════════════

Produce, in this order:

1. `TopicPicker.preview.tsx` — Artifact (A): an HTML/Tailwind React component
   that VISUALLY SIMULATES the terminal in the Claude Design iframe. Monospace,
   `#1e1e2e` base, colours inline via style={{}} (hex visible for review),
   borders drawn with literal box chars, @font-face for the attached
   CaskaydiaMono woff2. Render the 100×30 primary frame AND the 60×20 fallback
   frame, plus one frame with the Banner and one with the Dialog open.

2. `TopicPicker.ink.tsx` — Artifact (B): the SAME component decomposition, in
   Ink, importing real blink primitives from '@henryavila/blink-tui'
   (Pane/List/Footer/Banner/Dialog + useTokens/useGlyph + the headless useList*
   hooks). The app owns Ink's `useInput` and calls the hooks' intent methods.
   No <div>/className/style; no emoji/SVG; tokens not raw hex. Define
   `TopicPickerProps` (takes `topics: Topic[]`, `host`) identical to (A).

3. `## new blink primitives proposed` — for ANY capability this screen needed
   that blink lacks, a short spec per primitive: name, the GENERIC problem it
   solves (not "the wizard needs it" — the domain-neutral version), proposed
   props, and why it belongs in blink vs. staying app-level. Keep blink's prime
   directive: a primitive that only makes sense for this one app does NOT belong
   in blink — say so and keep it app-level. Likely candidates to evaluate:
   a header/status-bar, a tree-select, a key/value description list. Decide each.

4. `## glyph requests` — any domain glyph used but missing from blink's built-in
   set (laravel, tailscale, syncthing, …), each with proposed {nerd, unicode,
   ascii} variants for the registry.

The diff between (A) and (B) must be only at the leaf-render level
(<div>+style ↔ <Box>+props, <span> ↔ <Text>). Same sub-component names, same
state/hooks in both.

Follow Catppuccin / lazygit / k9s conventions when a detail is unspecified.
Don't ask clarifying questions unless something is STRUCTURALLY ambiguous.

Confirm you've ingested this by replying with exactly:
  Primed. send "go" to generate TopicPicker.
Do NOT generate any artifact in this first turn.
````

---

## related

- blink contract + API: `github.com/henryavila/blink-tui` README
- Manifest 2.0 schema: `docs/2026-05-28-mesh-manifest-v2-spec.md`
- Initiative / task T-304: `mesh-identity/.atomic-skills/initiatives/mesh-restructure-f96-tui-rebuild.md`
- Predecessor prompt (generic, pre-library): `docs/2026-05-28-modern-tui-claude-design-prompt.md`
</content>
</invoke>
