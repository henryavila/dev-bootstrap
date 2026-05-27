import { icons, pc, status } from './theme.js';

export function formatItemLabel(option, isSelected, isFocused) {
  const label = option.label ?? String(option.value);
  const isInstalled = option.installed ?? false;
  const statusIcon = isInstalled
    ? pc.green(icons.installed)
    : pc.yellow(icons.available);
  const checkbox = isSelected ? pc.green(icons.checkboxOn) : pc.dim(icons.checkboxOff);

  if (option.disabled) {
    return `${pc.dim(icons.locked)} ${pc.dim(label)}`;
  }
  return `${checkbox} ${statusIcon} ${isFocused ? label : pc.dim(label)}`;
}

export function formatHint(option, isSelected) {
  if (!option) return '';
  const isInstalled = option.installed ?? false;
  const parts = [];

  if (isInstalled && !isSelected) {
    parts.push(pc.red('deselect to remove'));
  } else if (!isInstalled && isSelected) {
    parts.push(pc.green('select to install'));
  } else if (isInstalled && isSelected) {
    parts.push(pc.dim('installed'));
  }

  if (option.desc) parts.push(pc.dim(option.desc));
  if (option.tier) parts.push(pc.dim(`tier: ${option.tier}`));
  if (option.requires?.length) {
    parts.push(pc.dim(`requires: ${option.requires.join(', ')}`));
  }
  return parts.join(pc.dim(' · '));
}

export function buildLegend() {
  return [
    `${pc.dim('Space/Tab to toggle')} ${pc.dim('·')} ${pc.dim('Enter to confirm')} ${pc.dim('·')} ${pc.dim('Type to search')}`,
    `${pc.green(icons.installed)} ${pc.dim('= installed')}  ${pc.yellow(icons.available)} ${pc.dim('= available')}`,
  ].join('\n');
}

export function formatTopicHeader(topicName, index, total, installedCount, totalCount) {
  return `${pc.dim(`${index + 1}/${total}`)}  ${topicName}  ${pc.dim(`${installedCount}/${totalCount} installed`)}`;
}
