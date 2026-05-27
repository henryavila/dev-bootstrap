import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';

export function parseItemsYaml(content) {
  const items = [];
  let current = null;

  for (const raw of content.split('\n')) {
    const line = raw.replace(/\r$/, '');

    if (/^\s*#/.test(line) || /^\s*$/.test(line)) continue;

    const itemStart = line.match(/^-\s+(\w+):\s*(.*)/);
    if (itemStart) {
      current = {};
      items.push(current);
      current[itemStart[1]] = parseValue(itemStart[2]);
      continue;
    }

    const field = line.match(/^\s+(\w+):\s*(.*)/);
    if (field && current) {
      current[field[1]] = parseValue(field[2]);
    }
  }

  return items;
}

function parseValue(raw) {
  let v = raw.trim();
  if (!v) return '';

  if (v.startsWith('[') && v.endsWith(']')) {
    return v
      .slice(1, -1)
      .split(',')
      .map((s) => s.trim().replace(/^["']|["']$/g, ''))
      .filter(Boolean);
  }

  if (v === 'true') return true;
  if (v === 'false') return false;

  const num = Number(v);
  if (!Number.isNaN(num) && v !== '') return num;

  return v.replace(/^["']|["']$/g, '');
}

export function readTopicManifest(topicDir) {
  const yamlPath = join(topicDir, 'items.yaml');
  if (!existsSync(yamlPath)) return null;
  const content = readFileSync(yamlPath, 'utf8');
  const items = parseItemsYaml(content);
  const topicName = basename(topicDir);
  return items.map((item) => ({
    topic: topicName,
    name: item.name ?? '',
    type: item.type ?? '',
    spec: item.spec ?? '',
    check: item.check ?? '',
    script: item.script ?? '',
    platforms: Array.isArray(item.platforms) ? item.platforms : [],
    desc: item.desc ?? '',
    requires: Array.isArray(item.requires) ? item.requires : [],
    post: item.post ?? '',
    rollback: item.rollback ?? '',
    required: item.required === true,
    uninstall_tier: typeof item.uninstall_tier === 'number' ? item.uninstall_tier : 0,
  }));
}

export function readAllManifests(topicsRoot, { platform = null } = {}) {
  const topicDirs = readdirSync(topicsRoot, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();

  const result = [];
  for (const dir of topicDirs) {
    const items = readTopicManifest(join(topicsRoot, dir));
    if (!items) continue;
    for (const item of items) {
      if (platform && item.platforms.length > 0 && !item.platforms.includes(platform)) {
        continue;
      }
      result.push(item);
    }
  }
  return result;
}

export function groupByTopic(items) {
  const groups = new Map();
  for (const item of items) {
    if (!groups.has(item.topic)) {
      groups.set(item.topic, []);
    }
    groups.get(item.topic).push(item);
  }
  return groups;
}
