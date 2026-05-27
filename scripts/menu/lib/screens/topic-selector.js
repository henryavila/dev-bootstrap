import * as p from '@clack/prompts';
import { isCancel } from '@clack/core';
import { icons, pc } from '../ui/theme.js';

const ALWAYS_ON = new Set([
  '00-core',
  '05-identity',
  '10-languages',
  '20-terminal-ux',
  '30-shell',
  '40-tmux',
  '50-git',
  '95-dotfiles-personal',
]);

const TOPIC_LABELS = {
  '45-docker': 'Docker',
  '60-web-stack': 'Web Stack',
  '70-remote-access': 'Remote Access',
  '80-claude-code': 'Claude Code',
  '82-ai-tools': 'AI Tools',
  '85-code-server': 'Code Server',
  '90-editor': 'Editor',
};

const TOPIC_HINTS = {
  '45-docker': 'Colima + Docker CLI + Compose',
  '60-web-stack': 'MySQL, Redis, Valet, mkcert + extras',
  '70-remote-access': 'Tailscale, mosh, SSH',
  '80-claude-code': 'Claude CLI, syncthing, moshi, claudebar',
  '82-ai-tools': 'mdprobe, atomic-skills, rtk',
  '85-code-server': 'Standalone code-server',
  '90-editor': 'Neovim default config',
};

export function getSelectableTopics(groupedItems, installedStatus) {
  const topics = [];
  for (const [topic, items] of groupedItems) {
    if (ALWAYS_ON.has(topic)) continue;
    const installed = items.filter(
      (i) => installedStatus.get(`${i.topic}/${i.name}`) === true,
    ).length;
    topics.push({
      value: topic,
      label: `${TOPIC_LABELS[topic] ?? topic} (${installed}/${items.length})`,
      hint: TOPIC_HINTS[topic] ?? '',
      installed,
      total: items.length,
    });
  }
  return topics;
}

export async function selectTopics(groupedItems, installedStatus, previousTopics = []) {
  const options = getSelectableTopics(groupedItems, installedStatus);
  if (options.length === 0) return [];

  const initialValues =
    previousTopics.length > 0
      ? previousTopics
      : options.filter((o) => o.installed > 0).map((o) => o.value);

  const result = await p.multiselect({
    message: 'Select opt-in topics to configure',
    options,
    initialValues,
    required: false,
  });

  if (isCancel(result)) return null;
  return result;
}

export function getAlwaysOnTopics() {
  return [...ALWAYS_ON];
}
