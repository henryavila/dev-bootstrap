import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { writeSelections, writeParams, SELECTIONS_PATH, PARAMS_PATH } from './selections-io.js';
import { readAllManifests } from './manifest-reader.js';

const STATE_DIR = join(
  process.env.XDG_STATE_HOME ?? join(homedir(), '.local', 'state'),
  'mesh-workstation',
);
const OLD_CONFIG = join(STATE_DIR, 'config.env');

export function detectLegacyConfig() {
  return existsSync(OLD_CONFIG) && !existsSync(SELECTIONS_PATH);
}

export function migrateLegacyConfig(topicsRoot, { platform = null } = {}) {
  if (!existsSync(OLD_CONFIG)) return null;

  const content = readFileSync(OLD_CONFIG, 'utf8');
  const vars = {};
  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq);
    let val = trimmed.slice(eq + 1);
    val = val.replace(/^["']|["']$/g, '');
    vars[key] = val;
  }

  const allItems = readAllManifests(topicsRoot, { platform });
  const selections = [];

  const INCLUDE_MAP = {
    INCLUDE_DOCKER: '45-docker',
    INCLUDE_WEBSTACK: '60-web-stack',
    INCLUDE_LARAVEL: '60-web-stack',
    INCLUDE_REMOTE: '70-remote-access',
    INCLUDE_AI_TOOLS: '82-ai-tools',
    INCLUDE_CODE_SERVER: '85-code-server',
    INCLUDE_EDITOR: '90-editor',
    INCLUDE_IDENTITY: '95-dotfiles-personal',
  };

  const enabledTopics = new Set();
  for (const [envVar, topic] of Object.entries(INCLUDE_MAP)) {
    if (vars[envVar] === '1') {
      enabledTopics.add(topic);
    }
  }

  const ALWAYS_ON = new Set([
    '00-core', '05-identity', '10-languages', '20-terminal-ux',
    '30-shell', '40-tmux', '50-git',
  ]);

  for (const item of allItems) {
    if (ALWAYS_ON.has(item.topic) || enabledTopics.has(item.topic)) {
      selections.push(`${item.topic}/${item.name}`);
    }
  }

  const params = {};
  if (vars.PHP_VERSIONS) params.MESH_PHP_VERSIONS = vars.PHP_VERSIONS;
  if (vars.PHP_DEFAULT) params.MESH_PHP_DEFAULT = vars.PHP_DEFAULT;
  if (vars.CODE_DIR) params.MESH_CODE_DIR = vars.CODE_DIR;
  if (vars.GIT_NAME) params.GIT_NAME = vars.GIT_NAME;
  if (vars.GIT_EMAIL) params.GIT_EMAIL = vars.GIT_EMAIL;
  if (vars.MESH_IDENTITY_REPO) params.MESH_IDENTITY_REPO = vars.MESH_IDENTITY_REPO;
  if (vars.MESH_IDENTITY_DIR) params.MESH_IDENTITY_DIR = vars.MESH_IDENTITY_DIR;

  writeSelections(selections);
  writeParams(params);

  return { selections, params, enabledTopics: [...enabledTopics] };
}
