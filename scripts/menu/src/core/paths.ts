/**
 * Filesystem paths the menu reads and writes.
 *
 * State-dir convention (initiative D-15):
 *   ~/.config/mesh/{selections.list,params.env}  — menu state + resolved options
 *   ~/.local/state/mesh/                          — engine install markers
 * Honor XDG_CONFIG_HOME / XDG_STATE_HOME when set.
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

const configHome =
  process.env.XDG_CONFIG_HOME && process.env.XDG_CONFIG_HOME.trim() !== ''
    ? process.env.XDG_CONFIG_HOME
    : path.join(homedir(), '.config');

const stateHome =
  process.env.XDG_STATE_HOME && process.env.XDG_STATE_HOME.trim() !== ''
    ? process.env.XDG_STATE_HOME
    : path.join(homedir(), '.local', 'state');

export const MESH_CONFIG_DIR = path.join(configHome, 'mesh');
export const MESH_STATE_DIR = path.join(stateHome, 'mesh');

export const SELECTIONS_FILE = path.join(MESH_CONFIG_DIR, 'selections.list');
export const PARAMS_FILE = path.join(MESH_CONFIG_DIR, 'params.env');

/** Install markers the engine writes after a successful item, keyed `<topic>__<item>`. */
export const MARKERS_DIR = path.join(MESH_STATE_DIR, 'markers');
