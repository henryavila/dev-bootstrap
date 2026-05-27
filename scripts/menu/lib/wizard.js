import * as p from '@clack/prompts';
import { isCancel } from '@clack/core';
import { dirname, join } from 'node:path';
import { readAllManifests, groupByTopic } from './core/manifest-reader.js';
import { scanAll } from './core/scanner.js';
import { readSelections, writeSelections, readParams, writeParams, selectionsToMap } from './core/selections-io.js';
import { computeDelta, autoSelectDependencies } from './core/delta.js';
import { selectTopics, getAlwaysOnTopics } from './screens/topic-selector.js';
import { selectItems } from './screens/item-selector.js';
import { promptParams } from './screens/param-prompts.js';
import { showSummary } from './screens/summary.js';

export async function runWizard({ dryRun = false, topicsRoot = null, platform = null } = {}) {
  const menuDir = dirname(new URL(import.meta.url).pathname);
  if (!topicsRoot) {
    topicsRoot = join(menuDir, '..', '..', '..', 'topics');
  }

  p.intro('mesh setup');

  const allItems = readAllManifests(topicsRoot, { platform });
  const grouped = groupByTopic(allItems);

  const s = p.spinner();
  s.start('Scanning installed items...');
  const installedStatus = await scanAll(allItems, { topicsRoot, platform: platform ?? 'mac' });
  s.stop('Scan complete.');

  const previousSelections = readSelections() ?? [];
  const previousParams = readParams();

  // Phase 1: topic selection
  const selectedTopics = await selectTopics(
    grouped,
    installedStatus,
    [...selectionsToMap(previousSelections).keys()],
  );
  if (selectedTopics === null) {
    p.outro('Cancelled.');
    return false;
  }

  // Phase 2: per-topic item selection
  const allSelectedEntries = [];

  for (const topic of getAlwaysOnTopics()) {
    const items = grouped.get(topic);
    if (!items) continue;
    for (const item of items) {
      allSelectedEntries.push(`${item.topic}/${item.name}`);
    }
  }

  const optInTopics = selectedTopics.filter((t) => grouped.has(t));
  for (let i = 0; i < optInTopics.length; i++) {
    const topic = optInTopics[i];
    const items = grouped.get(topic);
    const prevForTopic = previousSelections.filter((e) => e.startsWith(`${topic}/`));

    if (isAllOrNothing(items)) {
      for (const item of items) {
        allSelectedEntries.push(`${item.topic}/${item.name}`);
      }
      const names = items.map((it) => it.name).join(', ');
      p.log.step(`${topic}: ${names}`);
      continue;
    }

    const selected = await selectItems(topic, items, installedStatus, prevForTopic, {
      index: i,
      total: optInTopics.length,
    });

    if (selected === null) {
      p.outro('Cancelled.');
      return false;
    }
    allSelectedEntries.push(...selected);
  }

  const { selected: withDeps, added } = autoSelectDependencies(allItems, allSelectedEntries);
  if (added.length > 0) {
    p.log.info(`Auto-selected ${added.length} dep(s): ${added.map(shortName).join(', ')}`);
  }

  // Phase 3: parameters
  const params = await promptParams(selectedTopics, previousParams, { topicsRoot });
  if (params === null) {
    p.outro('Cancelled.');
    return false;
  }

  // Phase 4: summary + confirm
  const delta = computeDelta(allItems, previousSelections, withDeps);
  const confirmed = await showSummary(delta);
  if (!confirmed) {
    p.outro('No changes applied.');
    return false;
  }

  if (!dryRun) {
    writeSelections(withDeps);
    writeParams(params);
    p.log.success('Selections saved.');
  } else {
    p.log.info('Dry run — no files written.');
  }

  p.outro('Done.');
  return { selections: withDeps, params, delta };
}

function isAllOrNothing(items) {
  if (items.length <= 1) return true;
  const independentItems = items.filter((item) => {
    const isDependedOn = items.some((other) => other.requires?.includes(item.name));
    const hasDeps = item.requires?.length > 0;
    return !item.required && !isDependedOn && !hasDeps;
  });
  return independentItems.length === 0;
}

function shortName(entry) {
  const slash = entry.lastIndexOf('/');
  return slash >= 0 ? entry.slice(slash + 1) : entry;
}
