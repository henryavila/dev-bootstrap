import * as p from '@clack/prompts';
import { isCancel } from '@clack/core';
import { icons, pc } from '../ui/theme.js';

export async function showSummary(delta) {
  const { install, remove, keep } = delta;

  const lines = [];
  if (install.length > 0) {
    lines.push(`${pc.green('INSTALL')} (${install.length}):  ${install.map(shortName).join(', ')}`);
  }
  if (remove.length > 0) {
    lines.push(`${pc.red('REMOVE')}  (${remove.length}):  ${remove.map(shortName).join(', ')}`);
  }
  if (keep.length > 0) {
    const display = keep.length <= 8
      ? keep.map(shortName).join(', ')
      : keep.slice(0, 6).map(shortName).join(', ') + `, ... +${keep.length - 6}`;
    lines.push(`${pc.dim('KEEP')}    (${keep.length}):  ${pc.dim(display)}`);
  }

  if (lines.length === 0) {
    p.log.info('No changes to apply.');
    return false;
  }

  p.note(lines.join('\n'), 'Changes');

  if (install.length === 0 && remove.length === 0) {
    p.log.info('No changes to apply.');
    return false;
  }

  const confirmed = await p.confirm({
    message: 'Apply changes?',
    initialValue: true,
  });

  if (isCancel(confirmed) || !confirmed) return false;
  return true;
}

function shortName(entry) {
  const slash = entry.lastIndexOf('/');
  return slash >= 0 ? entry.slice(slash + 1) : entry;
}
