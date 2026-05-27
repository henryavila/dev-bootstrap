import { isCancel } from '@clack/core';
import { AutocompleteMultiselectPrompt } from '../ui/autocomplete-multiselect.js';
import { formatItemLabel, formatHint, formatTopicHeader } from '../ui/format.js';
import { icons, pc, symbol } from '../ui/theme.js';

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
    return {
      value: key,
      label: item.name,
      hint: item.desc,
      desc: item.desc,
      installed,
      disabled: item.required,
      tier: item.uninstall_tier > 0 ? `tier ${item.uninstall_tier}` : '',
      requires: item.requires,
    };
  });

  const initialValues = options
    .filter((o) => {
      if (previousSelections.length > 0) {
        return previousSelections.includes(o.value);
      }
      return o.installed;
    })
    .map((o) => o.value);

  const header = formatTopicHeader(topicName, index, total, installedCount, items.length);

  const prompt = new AutocompleteMultiselectPrompt({
    options,
    initialValues,
    render() {
      const title = `${pc.gray(icons.bar)}\n${symbol(this.state)}  ${header}\n`;
      const focused = this.focusedOption();

      switch (this.state) {
        case 'submit': {
          const chosen = this.options
            .filter((_, i) => this.selectedValues.has(i))
            .map((o) => pc.dim(o.label))
            .join(pc.dim(', '));
          return `${title}${pc.gray(icons.bar)}  ${chosen || pc.dim('none')}`;
        }
        case 'cancel':
          return `${title}${pc.gray(icons.bar)}  ${pc.strikethrough(pc.dim('cancelled'))}`;
        default: {
          const legendLine = `${pc.cyan(icons.bar)}  ${pc.dim('Enter/Space = toggle')} ${pc.dim('·')} ${pc.dim('Type to filter')} ${pc.dim('·')} ${pc.green(icons.installed)} ${pc.dim('installed')}  ${pc.yellow(icons.available)} ${pc.dim('available')}`;

          const searchLine = this.search
            ? `${pc.cyan(icons.bar)}  ${pc.dim('Filter:')} ${this.search}`
            : '';

          const rows = this.filteredIndices.map((realIdx, displayIdx) => {
            const opt = this.options[realIdx];
            const isFocused = displayIdx === this.cursor;
            const isSelected = this.selectedValues.has(realIdx);
            const label = formatItemLabel(opt, isSelected, isFocused);
            const hint = isFocused ? formatHint(opt, isSelected) : '';
            const line = hint ? `${label}  ${hint}` : label;
            return `${pc.cyan(icons.bar)}  ${line}`;
          });

          if (rows.length === 0) {
            rows.push(`${pc.cyan(icons.bar)}  ${pc.dim('No matches')}`);
          }

          const confirmFocused = this.cursorOnConfirm;
          const confirmRow = confirmFocused
            ? `${pc.cyan(icons.bar)}  ${pc.bgCyan(pc.bold(' Confirm '))} ${pc.dim('press Enter to continue')}`
            : `${pc.cyan(icons.bar)}  ${pc.dim('[ Confirm ]')}`;

          const parts = [title, legendLine];
          if (searchLine) parts.push(searchLine);
          parts.push(rows.join('\n'));
          parts.push(`${pc.cyan(icons.bar)}`);
          parts.push(confirmRow);
          parts.push(`${pc.cyan(icons.end)}`);
          return parts.join('\n');
        }
      }
    },
  });

  const result = await prompt.prompt();
  if (isCancel(result)) return null;
  return result;
}
