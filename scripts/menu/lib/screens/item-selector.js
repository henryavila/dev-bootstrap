import * as p from '@clack/prompts';
import { isCancel } from '@clack/core';
import { icons, pc } from '../ui/theme.js';

export async function selectItems(
  topicName,
  items,
  installedStatus,
  previousSelections = [],
  { index = 0, total = 1 } = {},
) {
  const installedCount = items.filter(
    (i) => installedStatus.get(`${i.topic}/${i.name}`) === true,
  ).length;

  const options = items.map((item) => {
    const key = `${item.topic}/${item.name}`;
    const installed = installedStatus.get(key) === true;
    const statusIcon = installed ? pc.green(icons.installed) : pc.yellow(icons.available);
    const action = installed ? pc.dim('installed') : pc.dim('available');

    return {
      value: key,
      label: `${statusIcon} ${item.name}`,
      hint: item.desc ? `${action} · ${item.desc}` : action,
    };
  });

  const initialValues = options
    .filter((o) => {
      if (previousSelections.length > 0) {
        return previousSelections.includes(o.value);
      }
      const item = items.find((i) => `${i.topic}/${i.name}` === o.value);
      return installedStatus.get(o.value) === true;
    })
    .map((o) => o.value);

  const result = await p.multiselect({
    message: `${topicName} (${index + 1}/${total}) — ${installedCount}/${items.length} installed`,
    options,
    initialValues,
    required: false,
  });

  if (isCancel(result)) return null;
  return result;
}
