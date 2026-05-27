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

export function getSelectableTopics(groupedItems, installedStatus) {
  const topics = [];
  for (const [topic, items] of groupedItems) {
    if (ALWAYS_ON.has(topic)) continue;
    const installed = items.filter(
      (i) => installedStatus.get(`${i.topic}/${i.name}`) === true,
    ).length;
    topics.push({
      value: topic,
      label: TOPIC_LABELS[topic] ?? topic,
      hint: `${installed}/${items.length} installed`,
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
