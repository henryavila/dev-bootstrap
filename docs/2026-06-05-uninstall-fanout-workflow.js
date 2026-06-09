export const meta = {
  name: 'uninstall-fanout-wave1',
  description: 'Frente B wave 1 — add uninstall() to AI+databases custom installers, one agent per unit + adversarial review',
  phases: [
    { title: 'Implement', detail: 'one agent per script writes uninstall()' },
    { title: 'Review', detail: 'adversarial reviewer per script' },
  ],
}

const WS = '/home/henry/mesh-workstation'

const UNITS = [
  'ai/install-bun.sh',
  'ai/install-claude.sh',
  'ai/install-moshi-hook.sh',
  'ai/moshi-hook-service-mac.sh',
  'ai/moshi-hook-service-wsl.sh',
  'databases/mac/mysql.sh',
  'databases/mac/redis.sh',
  'databases/mssql-driver.sh',
  'databases/postgresql.sh',
  'databases/wsl/mysql.sh',
  'databases/wsl/redis.sh',
]

const IMPL_SCHEMA = {
  type: 'object',
  required: ['file', 'classification', 'summary', 'syntax_ok'],
  additionalProperties: false,
  properties: {
    file: { type: 'string' },
    classification: { type: 'string', enum: ['real', 'revert', 'noop'] },
    summary: { type: 'string', description: 'one line: what uninstall() now does' },
    noop_reason: { type: 'string', description: 'required when classification=noop' },
    shared_change_needed: { type: 'string', description: 'empty if none; else describe the engine/helper change you did NOT make' },
    syntax_ok: { type: 'boolean', description: 'did `bash -n` on the file pass' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['file', 'verdict', 'severity'],
  additionalProperties: false,
  properties: {
    file: { type: 'string' },
    verdict: { type: 'string', enum: ['ok', 'needs_fix'] },
    severity: { type: 'string', enum: ['none', 'low', 'medium', 'high', 'critical'] },
    issues: { type: 'array', items: { type: 'string' } },
  },
}

const implPrompt = (u) => `Add an \`uninstall()\` function to the mesh-workstation custom installer script:
  ${WS}/topics/${u}

STEP 1 — read (read-only):
  - the target script ${WS}/topics/${u} — study install(), rollback(), check()
  - reference ${WS}/topics/web/extras/ngrok.sh — REAL removal, success-gated on the binary being gone
  - reference ${WS}/topics/ai/install-rtk.sh — guarded removal via recorded state file
  - the dispatch contract in ${WS}/scripts/lib/uninstall-engine.sh (~lines 300-345): uninstall() is sourced + run; the engine drops the install marker ONLY when uninstall() returns 0; rc 75 is reserved (means "no uninstall defined").

STEP 2 — write uninstall() that REVERSES install():
  - Installs a binary / package / service / git-clone -> REMOVE it for real: brew uninstall (cask or formula as install used), apt-get remove/purge + remove any apt source + keyring it added, launchctl/systemctl disable + rm the unit, rm the cloned dir. Where feasible RETURN SUCCESS only when the thing is actually gone (e.g. \`! command -v X\`) like ngrok, so the marker drop is honest.
  - Pure config / managed-block / symlink with nothing safely removable -> a DOCUMENTED no-op: \`uninstall() { :; }  # config-only: nothing to remove because <reason>\`. NEVER leave it absent; NEVER guess-delete user data.
  - Reverts config it created (managed block / symlink) -> remove ONLY what install() added.

HARD RULES:
  - Scope EVERY removal to mesh-managed paths. NEVER \`rm -rf\` a broad or user dir, never remove a shared dependency another bundle may use (e.g. don't \`brew uninstall\` openssl), never touch \$HOME wholesale.
  - errexit is OFF inside custom verbs — NEVER use \`set +e\` (the L03 lint bans it here); capture rc with \`cmd || rc=$?\`.
  - bash 3.2 floor on macOS (no \\b in [[ =~ ]], BSD awk). Under \`set -o pipefail\`, \`tool | grep -q\` has a broken-pipe race -> capture output first, then \`[[ =~ ]]\`.
  - Idempotent + safe when the thing is already gone (guard with command -v / [[ -e ]]).
  - Edit ONLY ${WS}/topics/${u}. Do NOT modify any other file. If a shared helper or engine change is needed, put it in shared_change_needed and do NOT make it.

STEP 3 — run \`bash -n ${WS}/topics/${u}\` and confirm it parses; set syntax_ok accordingly.

Return the structured result.`

const reviewPrompt = (impl, u) => `Adversarially review the \`uninstall()\` just added to:
  ${WS}/topics/${u}
The implementer classified it "${impl ? impl.classification : 'unknown'}"${impl && impl.noop_reason ? ` (no-op reason: ${impl.noop_reason})` : ''}.

Read the CURRENT file and the install()/rollback() it must reverse. Try hard to find a reason this uninstall() is WRONG or UNSAFE:
  1. Correctness — does it actually reverse install()? correct package name / path / service / clone dir? removes what install created and nothing it didn't?
  2. SAFETY (weight highest) — any rm that could hit a broad/user dir, a SHARED dependency, or something mesh did not install? any unscoped path? a drifted/foreign binary deleted without a guard? -> high/critical.
  3. No-op honesty — if classified noop, is it TRULY true that nothing is safely removable, or did the implementer skip real cleanup that install() clearly did? an unjustified no-op = needs_fix.
  4. Contract — no \`set +e\`; bash 3.2-safe; pipefail-safe; idempotent.
  5. Marker honesty — does it return success only when removal actually happened?

Default to needs_fix if you find any real safety issue. Be concrete in issues (file:line + what's wrong).`

phase('Implement')
const results = await pipeline(
  UNITS,
  (u) => agent(implPrompt(u), { label: `impl:${u}`, phase: 'Implement', schema: IMPL_SCHEMA }),
  (impl, u) => agent(reviewPrompt(impl, u), { label: `review:${u}`, phase: 'Review', schema: REVIEW_SCHEMA })
    .then((rev) => ({ unit: u, impl, review: rev })),
)

const clean = results.filter(Boolean)
const needsFix = clean.filter((r) => r.review && r.review.verdict === 'needs_fix')
const shared = clean.filter((r) => r.impl && r.impl.shared_change_needed && r.impl.shared_change_needed.trim() !== '')
log(`wave1: ${clean.length}/${UNITS.length} processed · ${needsFix.length} needs_fix · ${shared.length} flagged a shared change`)

return {
  processed: clean.length,
  total: UNITS.length,
  needs_fix: needsFix.map((r) => ({ unit: r.unit, severity: r.review.severity, issues: r.review.issues || [] })),
  shared_changes: shared.map((r) => ({ unit: r.unit, change: r.impl.shared_change_needed })),
  units: clean.map((r) => ({ unit: r.unit, classification: r.impl ? r.impl.classification : '?', summary: r.impl ? r.impl.summary : '', verdict: r.review ? r.review.verdict : '?' })),
}
