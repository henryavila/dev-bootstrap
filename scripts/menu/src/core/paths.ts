/**
 * Filesystem paths the menu reads and writes.
 *
 * State-dir convention (initiative D-15):
 *   ~/.config/mesh/{selections.list,params.env}  — menu state + resolved options
 *   ~/.local/state/mesh/installed/                — engine install markers
 * Honor XDG_CONFIG_HOME / XDG_STATE_HOME / MESH_INSTALL_STATE_DIR when set.
 *
 * The env-dependent paths are FUNCTIONS, resolved at call time — not module-load
 * constants — so an env change (a test pinning XDG_CONFIG_HOME, a wrapper
 * exporting it) is always honored and tests never touch real ~/.config state.
 * REPO_ROOT / TOPICS_DIR are stable and stay constants.
 */
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

/** Repo root — scripts/menu/src/core/paths.ts → up four levels. */
export const REPO_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../..',
);

/** topics/ directory holding the per-topic manifest.yaml files. */
export const TOPICS_DIR = path.join(REPO_ROOT, 'topics');

function envDir(name: string, fallback: () => string): string {
  const v = process.env[name];
  return v && v.trim() !== '' ? v : fallback();
}

export function meshConfigDir(): string {
  return path.join(envDir('XDG_CONFIG_HOME', () => path.join(homedir(), '.config')), 'mesh');
}

export function meshStateDir(): string {
  return path.join(
    envDir('XDG_STATE_HOME', () => path.join(homedir(), '.local', 'state')),
    'mesh',
  );
}

export function selectionsFile(): string {
  return path.join(meshConfigDir(), 'selections.list');
}

export function paramsFile(): string {
  return path.join(meshConfigDir(), 'params.env');
}

/**
 * Bundles the user deselected since the last apply (computeDelta.remove). The
 * Apply (setup.sh) runs uninstall-engine on these BEFORE installing, then
 * deletes the file. Empty body (header only) ⇒ nothing to remove.
 */
export function removalsFile(): string {
  return path.join(meshConfigDir(), 'removals.list');
}

/**
 * Install markers the engine writes (one `<topic>__<item>.env`). Matches
 * install-state.sh: MESH_INSTALL_STATE_DIR override → else <state>/mesh/installed.
 */
export function markersDir(): string {
  return envDir('MESH_INSTALL_STATE_DIR', () => path.join(meshStateDir(), 'installed'));
}
