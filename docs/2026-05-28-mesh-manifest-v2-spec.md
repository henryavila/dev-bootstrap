# mesh manifest.yaml v2 — schema spec

> **HISTORICAL ARCHIVE (2026-05-28 draft).** Live schema truth is
> `schema/manifest.schema.json` (includes `membership: mesh`) plus
> `docs/SPEC.md` §4. Required-always-on / “ALWAYS selected” rules here are
> **superseded** by `--no-mesh` unlock + catalog-omit behavior. Do not
> hand-edit catalogs from this draft alone.
>
> **Status:** historical draft (T-100 of F9.6 initiative). Approved corte ε
> layout (12 topics + 30 bundles) at the time. Supersedes the v1 `items.yaml`
> flat schema, but is itself superseded for membership / guest mode.
>
> **Original purpose:** hierarchical manifest reference for engine/TUI/
> validators/humans — retained for archaeology only.

---

## 0 · Decision Index

Maps the ratified decisions to the sections that implement them, so coverage
is checkable at a glance.

| decision | summary | implemented in |
|---|---|---|
| D-6 | `requires_bundles` cross-topic deps | §5, §7 |
| D-7 | `when:` conditional items (named + option-driven) | §3 |
| D-8 | `default_from` shell-derived default (text) | §4.4 |
| D-9 | `default_selected` fresh-install pre-marking | §6 |
| D-10 | Syncthing apply-pause banner | §11 |
| D-11 | Native bash consumption of v2 schema (no JS bridge) | §10 |
| D-12 / D-13 | TUI package / glyph palette — superseded by D-14 (now `blink-tui`); out of this spec's scope (owned by `manifest-reader.ts`, §10.3) | — |

---

## 1 · File location & naming

```
topics/
├── foundation/manifest.yaml          # required, visible+locked (ratified 2026-06-01)
├── identity/manifest.yaml            # required
├── dotfiles-personal/manifest.yaml   # required
├── git/manifest.yaml                 # required
├── shell-terminal/manifest.yaml      # required (was 20-terminal-ux + 30-shell + 40-tmux + 90-editor)
├── languages/manifest.yaml           # opt-in
├── databases/manifest.yaml           # opt-in (NEW)
├── web/manifest.yaml                 # opt-in (was 60-web-stack minus DBs)
├── containers/manifest.yaml          # opt-in (was 45-docker)
├── remote-access/manifest.yaml       # opt-in
├── syncthing/manifest.yaml           # opt-in (NEW — extracted from claude-code)
└── ai/manifest.yaml                  # opt-in (was 80-claude-code + 82-ai-tools)
```

**Renames from v1:**

- `items.yaml` → `manifest.yaml`
- Topic folders drop the `NN-` numeric prefix; ordering moves to
  `topic.order` field inside the manifest. Reason: prefix was visual
  ordering crutch; YAML field is explicit and editable without rename.

---

## 2 · Top-level structure

```yaml
topic:        { ... }      # required — topic-level metadata
bundles:      [ ... ]      # required — list of selectable bundles
```

That's it at the root. Everything else nests inside `bundles[].*`.

### 2.1 · `topic` block

| field | type | required | default | semantics |
|---|---|:---:|---|---|
| `label` | string | ✓ | — | display name shown in the topic-picker (e.g., "Web") |
| `hint` | string | — | empty | one-line tagline shown next to label (max ~60 chars) |
| `required` | boolean | — | `false` | `true` = topic always-on AND shown in the picker as a **locked** (pre-selected, non-deselectable) row. **NOT hidden** (ratified 2026-06-01, supersedes the earlier "invisible" intent). e.g., Foundation appears locked at the top |
| `order` | number | ✓ | — | sort key in topic-picker (10, 20, 30, ...). Reserve gaps for inserts |
| `description` | string | — | empty | longer description shown in topic detail (multi-line ok) |

### 2.2 · `bundles[]` items

Each bundle is a user-selectable unit. Atomic — items inside a bundle
are inherently part of the bundle (no per-item toggle).

| field | type | required | default | semantics |
|---|---|:---:|---|---|
| `name` | string | ✓ | — | unique within topic. kebab-case. used in `selections.list` |
| `label` | string | ✓ | — | display name (e.g., "Valet"). human-readable. |
| `desc` | string | ✓ | — | one-line user-facing description. Pattern: `<what> — <benefit>`. ~50-60 chars |
| `platforms` | string[] | — | `[mac, wsl]` | OS gate. If list is non-empty and current OS not in it, bundle is hidden |
| `required` | boolean | — | `false` | `true` = bundle always-on within its topic (if topic enabled). Implies non-removable |
| `default_selected` | boolean | — | `true` | initial selection state on fresh install. Most bundles default `true`; `code-server` and `gpg-signing` override to `false` |
| `requires_bundles` | string[] | — | `[]` | cross-topic deps. Format: `<topic>/<bundle>`. e.g., `[databases/mysql, databases/redis]` |
| `icon_name` | string | — | empty | key into glyph palette (e.g., `mysql`, `docker`). Modern TUI uses for visual badge. If unset, no icon |
| `items` | object[] | ✓ | — | install actions (see §2.3) |
| `options` | object[] | — | `[]` | user-configurable parameters (see §2.4) |

### 2.3 · `bundles[].items[]`

The atomic unit the engine executes. Most users never see these
directly; bundle UX abstracts them.

| field | type | required | default | semantics |
|---|---|:---:|---|---|
| `name` | string | ✓ | — | unique within bundle. kebab-case. used in install-state markers |
| `type` | string | ✓ | — | driver: `custom`, `brew-formula`, `brew-cask`, `apt`, `npm-global`, `npx`, `cargo`, `pip`, `git-clone` |
| `spec` | string | conditional | — | driver argument (package name, npm spec, etc.). Required for non-`custom` types |
| `script` | string | conditional | — | path relative to topic dir. Required for `type: custom` |
| `check` | string | — | empty | shell cmd that proves "installed" (overrides driver's default check) |
| `platforms` | string[] | — | inherits from bundle | per-item OS gate |
| `when` | string | — | empty | conditional execution (see §3) |
| `idempotent` | boolean | — | `false` | scanner skips probing; engine always re-runs. For cleanup/migration scripts |
| `uninstall_tier` | number | — | `0` | criticality 0-3 for uninstall ordering |
| `post` | string | — | empty | post-install hook (path to script) |
| `rollback` | string | — | empty | rollback script if install fails |

**Removed from v1:** `hidden`, `required` (at item level), `requires`
(replaced by bundle-level `requires_bundles` + ordering within bundle).

### 2.4 · `bundles[].options[]`

User-configurable parameters for a bundle. Engine exports the
resolved value as env var before running items. Replaces the
hardcoded `param-prompts.js` from v1.

| field | type | required | default | semantics |
|---|---|:---:|---|---|
| `name` | string | ✓ | — | unique within bundle. kebab-case |
| `type` | string | ✓ | — | `multiselect`, `select`, `toggle`, `text`, `secret` (see §4) |
| `label` | string | ✓ | — | prompt label |
| `env` | string | ✓ | — | env var name exposed to scripts (UPPER_SNAKE_CASE convention) |
| `description` | string | — | empty | extra context shown below label |
| `required` | boolean | — | `false` | force user response (vs. accept default silently) |
| `default` | any | — | — | default value if user doesn't choose (type-dependent) |
| `default_from` | string | — | empty | shell cmd whose stdout is used as default (for `text` only). e.g., `git config --get user.name` |
| `choices` | object[] | conditional | — | options for `select`/`multiselect` (see §4.1) |
| `derive_from` | string | — | empty | for `select`/`multiselect`: choices come from another option's selected values |
| `source` | string | — | empty | path to external file (one choice per line) for dynamic choices. e.g., `./data/php-versions.conf` |
| `required_min` | number | — | `0` | for `multiselect`: minimum picks (1 = at least one required) |

Mutual exclusion: at most one of `choices`, `derive_from`, `source` may be
set on a `select`/`multiselect` option (see §8 rule 15). All three are
**UI-only** — they drive the interactive prompt rendered by the TUI and are
parsed exclusively by `manifest-reader.ts` (§10.3); the bash engine parser
skips them (§10).

#### 2.4.1 · Choice object

Each entry in an option's `choices:` list is an inline map:

| field | type | required | default | semantics |
|---|---|:---:|---|---|
| `value` | string | ✓ | — | machine value exported / persisted when selected |
| `label` | string | ✓ | — | human-readable display label in the prompt |
| `default` | boolean | — | `false` | for choice-form options, whether this choice is pre-selected |

**Default semantics by subtype** (which field carries the default depends on
how the choice list is produced):

| option shape | default source |
|---|---|
| choice-form `multiselect` (static `choices:`) | per-choice `default: true` on each entry to pre-select |
| choice-form `select` | option-level `default` (scalar `value`) |
| source-form `multiselect` (`source:`/`derive_from:`) | option-level `default` (list of values) |
| `toggle` | option-level `default` (scalar boolean) |
| `text` / `secret` | option-level `default` (scalar) / `default_from` (text only) |

---

## 3 · `when:` conditional items

Item is skipped silently when condition is false. Two forms:

### 3.1 · Named external condition

References a function in `scripts/lib/conditions.sh`:

```yaml
items:
  - name: mosh-path-fix
    type: custom
    script: ./mac/mosh-path-fix.sh
    platforms: [mac]
    when: brew_prefix_custom        # ← named condition
```

**Available conditions** (defined in `scripts/lib/conditions.sh`):

| condition | meaning |
|---|---|
| `brew_prefix_custom` | Mac, brew prefix is not `/opt/homebrew` and not `/usr/local` |
| `wsl_corporate` | WSL with corporate cert chain detected |
| `wsl_systemd` | `/etc/wsl.conf` has `systemd=true` |
| `tailscale_authkey_present` | `TAILSCALE_AUTHKEY` env var set |
| `php_installed` | install-state marker(s) for the php item(s) in `languages/php` present (e.g. `languages__php-stack-mac.env` or `languages__php-stack-wsl.env`) |
| `is_root_owned_brew` | brew prefix is owned by root (sudo required for ops) |

Adding new conditions: append `cond_<name>()` function to
`conditions.sh`. List here as part of same PR.

### 3.2 · Inline option-driven

References a `toggle` option within the same bundle:

```yaml
bundles:
  - name: node
    items:
      - name: fnm-and-lts
        type: custom
        script: ./node-fnm.sh
      - name: npm-global-config
        type: custom
        script: ./npm-global.sh
        when: option.enable-npm-global    # ← bundle option as condition
    options:
      - name: enable-npm-global
        type: toggle
        label: "Configure global npm prefix"
        env: MESH_NODE_NPM_GLOBAL
        default: false
```

**Syntax:** `option.<option-name>` — resolves to the toggle's boolean
value. Only valid against `type: toggle` options within the same
bundle.

### 3.3 · Combining conditions

Not supported in v2 (no `and:`/`or:`). If you need multiple conditions,
write a single named condition in `conditions.sh` that ANDs them.

---

## 4 · Option types

### 4.1 · `multiselect`

User picks 0..N from a list.

```yaml
options:
  - name: extensions
    type: multiselect
    label: "PECL extensions"
    env: MESH_PHP_EXTENSIONS
    required_min: 0
    choices:
      - { value: mongodb, label: "MongoDB", default: true }
      - { value: redis, label: "Redis", default: true }
      - { value: imagick, label: "Imagick (graphics)", default: false }
      - { value: xdebug, label: "Xdebug", default: false }
```

Engine exports `MESH_PHP_EXTENSIONS="mongodb redis"` (space-separated
selected values).

Alternative dynamic choices via `source:`:

```yaml
options:
  - name: versions
    type: multiselect
    label: "PHP versions to install"
    env: MESH_PHP_VERSIONS
    source: ./data/php-versions.conf   # one value per line
    required_min: 1
    default: [8.4]
```

### 4.2 · `select`

User picks exactly 1.

```yaml
options:
  - name: default
    type: select
    label: "Default PHP version"
    env: MESH_PHP_DEFAULT
    derive_from: versions    # choices = whatever was picked in `versions`
```

Or static choices:

```yaml
options:
  - name: editor
    type: select
    label: "Default editor"
    env: EDITOR
    choices:
      - { value: nvim, label: "Neovim" }
      - { value: code, label: "VSCode" }
      - { value: vim, label: "Vim" }
    default: nvim
```

### 4.3 · `toggle`

Boolean.

```yaml
options:
  - name: composer
    type: toggle
    label: "Install Composer globally"
    env: MESH_PHP_COMPOSER
    default: true
```

Engine exports `MESH_PHP_COMPOSER=1` (true) or `MESH_PHP_COMPOSER=0`.

### 4.4 · `text`

Free-form text input. Supports `default_from:` for pre-fill.

```yaml
options:
  - name: user-name
    type: text
    label: "Git author name"
    env: GIT_NAME
    default_from: "git config --get user.name"
    required: true
```

If `default_from:` command exits 0 with non-empty stdout, that's the
pre-filled value the user can accept (Enter) or edit. If it fails or
returns empty, falls back to `default:` or empty placeholder.

### 4.5 · `secret`

Like `text` but input is masked. Persisted to `secrets.env`
(mode 0600), not `params.env` (see §4.6).

```yaml
options:
  - name: authtoken
    type: secret
    label: "ngrok auth token"
    env: NGROK_AUTHTOKEN
    description: "From https://dashboard.ngrok.com/auth"
    required: false
```

### 4.6 · Value persistence

Resolved option values are persisted so the engine can source them before
running items, and so re-runs honor prior input:

- **Non-secret values** (`multiselect`, `select`, `toggle`, `text`) are written
  to `~/.config/mesh/params.env` as shell-sourceable `KEY=value` lines, keyed
  by `option.env`. The engine sources this file and exports the variables before
  running a bundle's items.
- **Secret values** (`secret`) are written to the existing `secrets.env`
  (mode `0600`, managed by `scripts/lib/secrets.sh`), never to `params.env`.

> **RESOLVED — canonical state-dir convention (ratified 2026-06-01):**
> - `~/.config/mesh/` — **menu/user state:** `selections.list` (bundle selections) +
>   `params.env` (resolved non-secret option values). Honors `$XDG_CONFIG_HOME`.
> - `~/.local/state/mesh/` — **machine/install state:** install markers
>   (`installed/<topic>__<item>.env`) AND `secrets.env` (mode 0600). Honors
>   `$XDG_STATE_HOME`. The legacy `~/.local/state/mesh-workstation/secrets.env`
>   location is migrated here by `secrets.sh` (one-time mv if the old path exists).
>
> Mnemonic: **config = what the user chose** (re-runnable, syncable); **state =
> what this machine did** (host-local, not synced). T-200 (engine) + T-303 (TUI io)
> both read from these canonical roots.

---

## 5 · `requires_bundles:` — cross-topic dependencies

Bundle declares deps on other bundles by `<topic>/<bundle>` path:

```yaml
bundles:
  - name: valet
    label: "Valet"
    platforms: [mac]
    requires_bundles:
      - databases/mysql
      - databases/redis
    items:
      - name: mkcert
        type: brew-formula
        spec: mkcert
      - name: valet
        type: custom
        script: ./mac/valet.sh
      - name: launchdaemon-hardening
        type: custom
        script: ./mac/launchdaemon-hardening.sh
      - name: migrate-legacy-nginx
        type: custom
        script: ./mac/migrate-legacy-nginx.sh
        idempotent: true
```

### 5.1 · Behavior

**On selection of dependent:** menu auto-selects deps with banner.
- Example: select `web/valet` → menu marks `databases/mysql` and
  `databases/redis` automatically. Banner: `Auto-selected: databases/mysql, databases/redis (Valet requires)`.

**On deselection of dep that has dependents:** menu prompts.
- Example: user unselects `databases/mysql` while `web/valet` still
  selected → modal:
  > MySQL is required by Valet. Choose:
  > (a) Keep MySQL selected
  > (b) Also unselect Valet

**On apply:** engine computes topological order of selected bundles
(deps first). MySQL installs before Valet, always.

### 5.2 · Cycles

Validator rejects manifest sets with circular `requires_bundles`. No
runtime cycle resolution.

### 5.3 · Missing target

Validator rejects `requires_bundles: foo/bar` if topic `foo` or
bundle `bar` doesn't exist.

---

## 6 · `default_selected:` semantics

| state of `selections.list` | behavior |
|---|---|
| file doesn't exist (fresh install) | each opt-in bundle uses its `default_selected` value (`true` default; `false` override on `code-server` and `gpg-signing`) |
| file exists (re-run / update) | user's prior selections honored; bundles added to manifest since last save use their `default_selected` value |

`required: true` bundles are ALWAYS selected regardless of
`default_selected` or `selections.list` content.

`required: true` topics are always present (their bundles still respect
the rules above; e.g., `git/gpg-signing` is `default_selected: false`
within a required topic).

---

## 7 · Complete example — `topics/web/manifest.yaml`

```yaml
topic:
  label: "Web"
  hint: "Valet/nginx + mailpit + ngrok"
  required: false
  order: 70
  description: |
    Local web development stack. Mac uses Valet (handles nginx + dnsmasq
    + HTTPS); WSL hand-rolls nginx + php-fpm. Optional dev extras for
    SMTP catching and public tunneling.

bundles:

  - name: valet
    label: "Valet"
    desc: "Laravel Valet — *.localhost with HTTPS, zero config"
    platforms: [mac]
    icon_name: laravel
    requires_bundles:
      - databases/mysql
      - databases/redis
    items:
      - name: mkcert
        type: brew-formula
        spec: mkcert
      - name: valet
        type: custom
        script: ./mac/valet.sh
      - name: launchdaemon-hardening
        type: custom
        script: ./mac/launchdaemon-hardening.sh
      - name: migrate-legacy-nginx
        type: custom
        script: ./mac/migrate-legacy-nginx.sh
        idempotent: true

  - name: nginx-php-fpm
    label: "nginx + php-fpm"
    desc: "nginx + php-fpm + mkcert — HTTPS wildcard on WSL"
    platforms: [wsl]
    icon_name: nginx
    requires_bundles:
      - languages/php
      - databases/mysql
      - databases/redis
    items:
      - name: packages
        type: custom
        script: ./wsl/packages.sh
      - name: mkcert
        type: custom
        script: ./wsl/mkcert.sh
      - name: nginx-sites
        type: custom
        script: ./wsl/nginx-sites.sh

  - name: mailpit
    label: "Mailpit"
    desc: "Local SMTP catcher — see every dev email"
    icon_name: mail
    items:
      - name: mailpit
        type: custom
        script: ./extras/mailpit.sh

  - name: ngrok
    label: "ngrok"
    desc: "Public HTTPS tunnel — share localhost for testing"
    icon_name: globe
    options:
      - name: authtoken
        type: secret
        label: "ngrok auth token"
        env: NGROK_AUTHTOKEN
        description: "From https://dashboard.ngrok.com/auth"
        required: false
    items:
      - name: ngrok
        type: custom
        script: ./extras/ngrok.sh
```

---

## 8 · Validation rules (enforced by `validate-manifest.sh`)

Hard errors (manifest rejected):

1. Missing `topic.label`, `topic.order`, or `bundles[]`.
2. Bundle missing `name`, `label`, `desc`, or `items[]`.
3. Item missing `name` or `type`.
4. Item with `type: custom` missing `script`.
5. Item with non-`custom` type missing `spec`.
6. `bundle.name` duplicated within same topic.
7. `item.name` duplicated within same bundle.
8. `option.name` duplicated within same bundle.
9. `requires_bundles` entry points to non-existent topic/bundle.
10. `requires_bundles` creates a cycle.
11. `option.derive_from` references non-existent option.
12. `when: option.X` references non-existent option or non-`toggle` option.
13. `when: <name>` references undefined named condition.
14. For a `multiselect`, `required_min` exceeds the number of choices marked
    `default: true` (choice-form) or `len(default)` (source-form).
15. More than one of `option.choices`, `option.derive_from`, `option.source`
    set on the same `select`/`multiselect` option (the three are mutually
    exclusive).
16. `option.derive_from` or `option.source` set on an option whose `type` is
    not `select` or `multiselect`.
17. `option.env` duplicated within the same bundle.
18. Bundle with `required: true` AND `default_selected: false` (always-on yet
    default-off is contradictory).
19. Option with `default_from:` but `type` is not `text`.

Soft warnings (manifest accepted):

- `bundle.desc` longer than 80 chars (terminal hint truncation risk).
- `topic.hint` longer than 60 chars.
- Bundle with `default_selected: false` but no `desc` mentioning opt-in nature.
- `uninstall_tier` outside 0-3.

---

## 9 · Migration matrix — v1 to v2

| v1 topic | v2 topic(s) | notes |
|---|---|---|
| `00-core` | `foundation` | `required: true` → visible in picker as a locked row (ratified 2026-06-01) |
| `05-identity` | `identity` | unchanged scope |
| `10-languages` | `languages` | `required` was true → now `false` (PHP isn't universal) |
| `20-terminal-ux` | `shell-terminal` | merged with 30/40/90 |
| `30-shell` | `shell-terminal` | merged |
| `40-tmux` | `shell-terminal` | merged as `tmux` bundle |
| `45-docker` | `containers` | rename |
| `50-git` | `git` | unchanged scope |
| `60-web-stack` | `web` + `databases` | DBs extracted to own topic |
| `70-remote-access` | `remote-access` | + `code-server` bundle (moved from 85) |
| `80-claude-code` | `ai` + `syncthing` | syncthing extracted to own topic |
| `82-ai-tools` | `ai` | merged with claude-code |
| `85-code-server` | `remote-access` | moved as bundle |
| `90-editor` | `shell-terminal` | nvim becomes a bundle in shell-terminal |
| `95-dotfiles-personal` | `dotfiles-personal` | rename (drop `95-` prefix) |

### 9.1 · Bundle reorganization within `60-web-stack` → `web` + `databases`

| v1 item | v2 location |
|---|---|
| `mysql-mac`, web-stack-wsl-packages's mysql-server-8.0 | `databases/mysql` bundle |
| `redis-mac`, web-stack-wsl-packages's redis-server | `databases/redis` bundle |
| `postgres` (was extra) | `databases/postgresql` bundle |
| `mssql-driver` (was extra) | `databases/mssql-driver` bundle |
| `mkcert-mac`, `valet`, `valet-launchdaemon-hardening`, `migrate-legacy-nginx` | `web/valet` bundle |
| `web-stack-wsl-packages` (nginx/php-fpm parts), `web-stack-wsl-mkcert`, `web-stack-wsl-nginx-sites` | `web/nginx-php-fpm` bundle |
| `mailpit` (was extra) | `web/mailpit` bundle |
| `ngrok` (was extra) | `web/ngrok` bundle |

### 9.2 · Items that disappear

- `hidden: true` items (`valet-launchdaemon-hardening`,
  `migrate-legacy-nginx`, `php-orphan-ini-cleanup-mac`) — they all
  become regular items inside their bundle. The `hidden` field is
  removed from the schema entirely.
- `-mac`/`-wsl` suffixes on item names — dropped **only** where the suffix
  distinguished OS variants of the *same logical install* (now a single item
  name + per-item `platforms:`). The bundle's `platforms:` field handles
  bundle-level OS gating; per-item `platforms:` is available when a bundle has
  mixed-OS items.

  **Keep distinct names** where mac and wsl genuinely run different items.
  Example (corte ε §3, `topics/syncthing/manifest.yaml`):
  `syncthing-binary-mac` (brew) / `syncthing-binary-wsl` (apt) /
  `syncthing-service-mac` / `syncthing-service-wsl` are four distinct items —
  the mac and wsl variants do different work (different driver, different
  service script), so they retain distinct names + per-item `platforms:`.
  Collapsing them to two names (`syncthing-binary`, `syncthing-service`) would
  violate validation rule 7 (duplicate `item.name` within a bundle) once both
  platform variants coexist in the same bundle.

---

## 10 · Engine parser contract — `yaml-parse.sh` v2

The v1 parser is a hand-written bash-3.2 flat walker that emits shell-evaluable
`ITEM_<i>_<KEY>=…` lines plus a final `__YAML_PARSE_OK=1` sentinel. **All of its
safety discipline carries forward unchanged**: bash-3.2 compatible (macOS ships
3.2), 2-space indent, tabs forbidden in the indent, careful shell-escaping of
values (`\\ " $ \``), rejection of anchors/aliases/tags/multi-line/multi-doc,
and the sentinel-verification contract (consumers `eval` the output then assert
`__YAML_PARSE_OK=1` — **never** `eval "$(yaml-parse.sh …)"` directly, since
command substitution discards the parser's exit code under `set -e`). v2 extends
the walker to the **3-level nesting** of this schema. (D-11; T-200)

**Scope boundary — what the bash walker does NOT parse.** The engine never
renders an interactive prompt; it only consumes the *resolved* option value from
`params.env` (§4.6). Therefore the bash walker emits only option **scalars**
(`NAME`, `TYPE`, `ENV`, `LABEL?`, `REQUIRED`, `REQUIRED_MIN?`, `DEFAULT?`,
`DEFAULT_FROM?`, `WHEN?`) and **gracefully skips** the `choices:` /
`derive_from:` / `source:` sub-trees. Those are UI-only and parsed by
`manifest-reader.ts` (the TS reader, §10.3) to drive the prompt. This keeps the
bash walker at a maximum of 3 nesting levels — no 4th indent level and no
inline-map (`{ value: …, label: … }`) tokenizer is required in bash (v1 has
neither, and rejects nested maps).

### 10.1 · Output shape (shell-evaluable)

```sh
TOPIC_LABEL="Web"
TOPIC_HINT="Valet/nginx + mailpit + ngrok"
TOPIC_REQUIRED=0
TOPIC_ORDER=70
BUNDLE_COUNT=4

BUNDLE_0_NAME="valet"
BUNDLE_0_LABEL="Valet"
BUNDLE_0_DESC="Laravel Valet — *.localhost with HTTPS, zero config"
BUNDLE_0_ICON_NAME="laravel"
BUNDLE_0_PLATFORMS_COUNT=1
BUNDLE_0_PLATFORMS_0="mac"
BUNDLE_0_REQUIRES_BUNDLES_COUNT=2
BUNDLE_0_REQUIRES_BUNDLES_0="databases/mysql"
BUNDLE_0_REQUIRES_BUNDLES_1="databases/redis"

BUNDLE_0_ITEM_COUNT=4
BUNDLE_0_ITEM_0_NAME="mkcert"
BUNDLE_0_ITEM_0_TYPE="brew-formula"
BUNDLE_0_ITEM_0_SPEC="mkcert"
BUNDLE_0_ITEM_3_NAME="migrate-legacy-nginx"
BUNDLE_0_ITEM_3_TYPE="custom"
BUNDLE_0_ITEM_3_SCRIPT="./mac/migrate-legacy-nginx.sh"
BUNDLE_0_ITEM_3_IDEMPOTENT=1

BUNDLE_3_OPTION_COUNT=1
BUNDLE_3_OPTION_0_NAME="authtoken"
BUNDLE_3_OPTION_0_TYPE="secret"
BUNDLE_3_OPTION_0_ENV="NGROK_AUTHTOKEN"
BUNDLE_3_OPTION_0_REQUIRED=0

__YAML_PARSE_OK=1
```

> `valet` declares neither `required` nor `default_selected` in the §7
> manifest, so the walker emits **neither** `BUNDLE_0_REQUIRED` nor
> `BUNDLE_0_DEFAULT_SELECTED` — absent optional fields are not emitted (see the
> naming note below). No `BUNDLE_3_OPTION_0_CHOICES_*` keys appear either: the
> `authtoken` secret has no `choices`, and even if it did, the walker skips
> `choices`/`derive_from`/`source` entirely (§10 scope boundary).

A `databases/manifest.yaml` example, shown as its own separate block to avoid
grafting databases onto the web sample, would emit a gated sub-item like this
(the `mssql-driver` bundle's `sqlsrv-php-ext` item carries `when: php_installed`):

```sh
# topics/databases/manifest.yaml — mssql-driver bundle (its own bundle index)
BUNDLE_3_NAME="mssql-driver"
BUNDLE_3_ITEM_1_NAME="sqlsrv-php-ext"
BUNDLE_3_ITEM_1_TYPE="custom"
BUNDLE_3_ITEM_1_SCRIPT="./mssql/sqlsrv-ext.sh"
BUNDLE_3_ITEM_1_WHEN="php_installed"
```

Naming: `TOPIC_*` for the topic block; `BUNDLE_<b>_*` for bundle scalars;
`BUNDLE_<b>_<KEY>_COUNT` + `BUNDLE_<b>_<KEY>_<n>` for bundle lists
(`PLATFORMS`, `REQUIRES_BUNDLES`); `BUNDLE_<b>_ITEM_<i>_*` and
`BUNDLE_<b>_OPTION_<o>_*` for nested items/options. Option scalars only
(`NAME`, `TYPE`, `ENV`, `LABEL`, `REQUIRED`, `REQUIRED_MIN`, `DEFAULT`,
`DEFAULT_FROM`, `WHEN`) are emitted — the `choices`/`derive_from`/`source`
sub-trees are UI-only and skipped (§10 scope boundary). Booleans normalize to
`1`/`0`. Keys upper-case with `-`→`_`.

**Emission policy (single rule):** the parser emits **only keys present in the
YAML** — absent optional fields are simply not emitted. Schema defaults are NOT
materialized by the parser; **both** consumers (the bash engine and the TS
reader) apply the schema defaults themselves (`default_selected=true`,
`required=false`, etc.) via `${VAR:-default}` on the engine side and typed
defaults in `manifest-reader.ts`. This is why the §7 `valet` bundle — which
declares neither field — emits no `BUNDLE_0_REQUIRED` and no
`BUNDLE_0_DEFAULT_SELECTED`.

### 10.2 · Indent map (2-space, fixed)

| indent | construct |
|---:|---|
| 0 | `topic:` / `bundles:` keys; `topic.*` scalars sit at 2 under `topic:` |
| 2 | `- name:` (bundle start) |
| 4 | bundle scalar (`label`, `desc`, …) / `items:` / `options:` keys |
| 6 | `- name:`/`- key:` (item or option start), and `- value` bundle-list entries |
| 8 | item/option scalar (the `choices:`/`derive_from:`/`source:` sub-trees are skipped by the bash walker — see §10) |

**Indent-6 routing (state-machine rule, mirrors v1's `in_list_for`).** At
indent 6 the routing depends on the most recent open indent-4 list key:

- under `items:` → an **ITEM start** (`- name:`),
- under `options:` → an **OPTION start** (`- name:`),
- under a scalar list key (`requires_bundles:` / `platforms:`) → a `- value`
  **list entry**.

A `- value` (no colon) appearing under `items:` or `options:` is an **error**
(those keys require maps, not bare scalars), exactly as v1 errors on a block-list
item with no preceding scalar-list key.

Behavioural tests are mandatory (T-402): nested counts, `when:` passthrough,
`requires_bundles` lists, the indent-6 routing branches above, graceful skip of
the `choices`/`derive_from`/`source` sub-trees, platform gating, the sentinel,
and rejection of every unsupported construct the v1 parser already rejects.

### 10.3 · Two independent consumers

The bash parser feeds the **engine** (`install-engine.sh` / `uninstall-engine.sh`).
The blink-tui **app** has its own strict TypeScript reader (`manifest-reader.ts`,
T-301) producing typed `Topic[] / Bundle[] / Item[] / Option[]`. Both read the
same `manifest.yaml`; neither preprocesses for the other (no JS-side bridge).

### 10.4 · Validator META mode (`MESH_YAML_META=1`)

The default engine output skips the `choices` / `derive_from` / `source`
sub-trees (§10 scope boundary). But `validate-manifest.sh` (§8 rules 11/14/15/16)
needs to *know they exist* without a 4th-level inline-map tokenizer. So
`yaml-parse.sh` accepts an opt-in env flag `MESH_YAML_META=1` that additionally
emits, per option:

```sh
BUNDLE_<b>_OPTION_<o>_HAS_CHOICES=1            # choices: block present
BUNDLE_<b>_OPTION_<o>_CHOICE_COUNT=N           # number of '- ' entries under it
BUNDLE_<b>_OPTION_<o>_CHOICE_DEFAULT_COUNT=M   # entries containing `default: true`
BUNDLE_<b>_OPTION_<o>_DERIVE_FROM="versions"   # derive_from scalar
BUNDLE_<b>_OPTION_<o>_SOURCE="./data/x.conf"   # source scalar
```

The choice meta is produced by **counting** lines while the subtree is skipped
(no inline-map parsing — the `default: true` substring is matched on the entry
line, which covers both the inline `{ …, default: true }` and block forms).
This keeps the bash walker at 3 nesting levels. **The default (engine) output is
unchanged** — META keys appear only when the flag is set, so the §10.1 contract
stands for `install-engine.sh` / `uninstall-engine.sh`. The TS reader does its
own full parse of these sub-trees (§10.3) and ignores META mode.

---

## 11 · Syncthing apply-pause (D-10)

The `syncthing` bundle includes a final item `post-install-banner` with
`idempotent: true`. During the **apply phase** (not the menu) it prints the admin
URL + pairing steps and blocks on `read -p "press enter once paired" </dev/tty`
before apply continues, so the manual pairing step cannot be silently skipped:

```yaml
# topics/syncthing/manifest.yaml (excerpt)
- name: post-install-banner
  type: custom
  script: ./post-install-banner.sh   # echo URL + steps, then read </dev/tty
  idempotent: true
```

The banner is pure `echo` + `read` — zero side effects, safe to re-run every
apply. Accepted risk: a simple blocking `read` (no timeout) in interactive apply;
in `--non-interactive` runs the script skips the `read` and only prints.

---

## 12 · Open questions for follow-up

1. **`option.adds_item` deprecated?** §3.2 inline `when: option.<name>`
   covers the same case more uniformly. Confirm `adds_item` is not
   needed.
2. **`item.post` and `item.rollback`** — keep as-is from v1, or move
   to a dedicated `hooks:` block per bundle?
3. **Topic-level options** — currently options are bundle-scoped only.
   Should there be topic-level options that affect multiple bundles?
   (Not in MVP; defer.)
4. **`bundle.tags` for search** — e.g., `tags: [database, ssl, daemon]`
   to enable richer `/` search in TUI. Defer to post-MVP.
5. **i18n** — all `label`/`desc`/`hint` in EN per session decision.
   Future: add `_pt`, `_es` variants? Defer.

---

## 13 · Changelog

- **2026-05-28** — v2.0.0 draft. Initial spec. Schema, validation rules,
  migration matrix.
- **2026-05-28** (augment) — added §10 engine parser contract
  (`yaml-parse.sh` v2 shell-eval output shape + indent map + sentinel discipline,
  carried from v1) and §11 Syncthing apply-pause (D-10); renumbered Open
  questions → §12, Changelog → §13.
- **2026-05-28** (review pass) — applied 10 adversarial-review fixes:
  - **§10 scope boundary:** bash walker emits option *scalars* only and
    gracefully skips `choices:`/`derive_from:`/`source:` (UI-only, owned by
    `manifest-reader.ts`); removes the need for a 4th indent level / inline-map
    tokenizer in bash. Removed `_CHOICES_*` keys from the §10.1 sample.
  - **§10.1 emission policy:** single rule — parser emits only keys present in
    YAML; both consumers apply schema defaults. Removed `BUNDLE_0_REQUIRED` /
    `BUNDLE_0_DEFAULT_SELECTED` from the `valet` sample (it declares neither).
  - **§10.1 stray comment:** relocated the `databases/mssql-driver`
    `when: php_installed` example into its own separate bundle block (no longer
    grafted onto the web/ngrok sample).
  - **§10.2 indent-6 routing:** added the explicit state-machine rule
    (items → ITEM, options → OPTION, scalar list key → `- value`; bare
    `- value` under items/options is an error).
  - **§2.4.1 Choice object** added (`value`/`label`/`default`); per-subtype
    default semantics stated explicitly.
  - **§8 validation:** rules 15/16 collapsed into one mutual-exclusion rule for
    `{choices, derive_from, source}`; reworded rule 14 (`required_min` vs choices
    marked `default: true` / `len(default)`); added rules 16–18 (`derive_from`/
    `source` only on select/multiselect; unique `option.env` per bundle;
    reject `required: true` + `default_selected: false`).
  - **§3.1** `php_installed` reworded to per-item marker keying
    (`languages__php-stack-{mac,wsl}.env`), not "bundle".
  - **§9.2** `-mac`/`-wsl` drop qualified to OS-variant-of-same-install only;
    syncthing four-item example retained as the keep-distinct-names case.
  - **§4.6 Value persistence** added (`params.env` for non-secret, `secrets.env`
    for secret) with a FLAG on the unreconciled state-dir naming
    (`~/.local/state/mesh/` vs `~/.local/state/mesh-workstation/` vs
    `~/.config/mesh/`) to resolve in T-200/T-303.
  - **§0 Decision Index** added (D-6..D-13 → implementing sections).
- **2026-06-01** — engine implementation landed (T-200/T-201/T-103):
  - `yaml-parse.sh` rewritten for the 3-level schema (§10.1 output shape) +
    behavioural tests; **§10.4 Validator META mode** added (`MESH_YAML_META=1`
    emits choices/derive_from/source metadata for the validator without a 4th
    indent level).
  - `conditions.sh` implements the six named `when:` conditions (§3.1) +
    `cond_eval`/`cond_is_known`/`cond_list` API.
  - `validate-manifest.sh` enforces all §8 rules (forward-ref `requires_bundles`
    tolerated as a warning during migration; `--strict` promotes to error) +
    `schema/manifest.schema.json` for editor/TS shape hints. Wired into
    pre-commit (lint L20) and CI.
