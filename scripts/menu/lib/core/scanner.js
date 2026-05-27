import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { readFileSync } from 'node:fs';

export function checkItem(item, { topicsRoot, platform = 'mac' } = {}) {
  if (item.check) {
    return runShellCheck(item.check);
  }

  if (item.type === 'custom') {
    if (!item.script) return false;
    const topicDir = join(topicsRoot, item.topic);
    const scriptPath = item.script.startsWith('./')
      ? join(topicDir, item.script)
      : item.script;
    return checkCustomScript(scriptPath);
  }

  return checkViaDriver(item);
}

function runShellCheck(cmd) {
  try {
    execSync(cmd, { stdio: 'pipe', timeout: 5_000 });
    return true;
  } catch {
    return false;
  }
}

function checkCustomScript(_scriptPath) {
  // Custom scripts define check() but sourcing them is fragile (dependencies,
  // top-level code). Without a manifest `check:` field, skip — the item shows
  // as "available" in the menu, which is a safe default.
  return false;
}

function checkViaDriver(item) {
  const spec = item.spec;
  if (!spec) return false;

  switch (item.type) {
    case 'brew-formula':
      return runShellCheck(`brew list --formula -- ${spec} 2>/dev/null`);
    case 'brew-cask':
      return runShellCheck(`brew list --cask -- ${spec} 2>/dev/null`);
    case 'apt':
      return runShellCheck(`dpkg -s -- ${spec} 2>/dev/null`);
    case 'npm-global':
      return runShellCheck(`npm list -g ${spec} 2>/dev/null`);
    case 'cargo':
      return runShellCheck(`command -v ${spec} 2>/dev/null`);
    case 'pip':
      return runShellCheck(`pip show ${spec} 2>/dev/null`);
    case 'git-clone':
    case 'npx':
      return false;
    default:
      return false;
  }
}

export function scanAll(items, { topicsRoot, platform = 'mac' } = {}) {
  const brewFormulas = [];
  const brewCasks = [];
  const results = new Map();

  for (const item of items) {
    if (item.type === 'brew-formula' && !item.check && item.spec) {
      brewFormulas.push(item);
    } else if (item.type === 'brew-cask' && !item.check && item.spec) {
      brewCasks.push(item);
    }
  }

  const installedFormulas = batchBrewCheck('--formula', brewFormulas.map((i) => i.spec));
  const installedCasks = batchBrewCheck('--cask', brewCasks.map((i) => i.spec));

  for (const item of brewFormulas) {
    results.set(`${item.topic}/${item.name}`, installedFormulas.has(item.spec));
  }
  for (const item of brewCasks) {
    results.set(`${item.topic}/${item.name}`, installedCasks.has(item.spec));
  }

  for (const item of items) {
    const key = `${item.topic}/${item.name}`;
    if (results.has(key)) continue;
    results.set(key, checkItem(item, { topicsRoot, platform }));
  }

  return results;
}

function batchBrewCheck(flag, specs) {
  if (specs.length === 0) return new Set();
  try {
    const output = execSync(`brew list ${flag} 2>/dev/null`, {
      stdio: 'pipe',
      timeout: 10_000,
      encoding: 'utf8',
    });
    const installed = new Set(output.trim().split('\n').map((l) => l.trim()));
    return new Set(specs.filter((s) => installed.has(s)));
  } catch {
    return new Set();
  }
}
