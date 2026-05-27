import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';

const ENGINE_DIR = join(dirname(new URL(import.meta.url).pathname), '..', '..', '..', 'lib');

export function checkItem(item, { topicsRoot, platform = 'mac' } = {}) {
  const topicDir = join(topicsRoot, item.topic);

  if (item.check) {
    return runShellCheck(item.check);
  }

  if (item.type === 'custom' && item.script) {
    return checkCustomScript(item, topicDir);
  }

  return checkViaDriver(item, { platform });
}

function runShellCheck(cmd) {
  try {
    execSync(cmd, { stdio: 'pipe', timeout: 10_000 });
    return true;
  } catch {
    return false;
  }
}

function checkCustomScript(item, topicDir) {
  const scriptPath = item.script.startsWith('./')
    ? join(topicDir, item.script)
    : item.script;
  try {
    execSync(
      `bash -c 'source "${ENGINE_DIR}/log.sh"; source "${ENGINE_DIR}/env.sh"; source "${scriptPath}"; if declare -f check >/dev/null 2>&1; then check; else exit 1; fi'`,
      { stdio: 'pipe', timeout: 15_000 },
    );
    return true;
  } catch {
    return false;
  }
}

function checkViaDriver(item, { platform }) {
  const driverMap = {
    'brew-formula': (spec) => runShellCheck(`brew list --formula ${spec} 2>/dev/null`),
    'brew-cask': (spec) => runShellCheck(`brew list --cask ${spec} 2>/dev/null`),
    apt: (spec) => runShellCheck(`dpkg -s ${spec} 2>/dev/null`),
    'npm-global': (spec) => runShellCheck(`npm list -g ${spec} 2>/dev/null`),
    cargo: (spec) => runShellCheck(`cargo install --list 2>/dev/null | grep -q "^${spec} "`),
    pip: (spec) => runShellCheck(`pip show ${spec} 2>/dev/null`),
    'git-clone': () => false,
    npx: () => false,
  };

  const driver = driverMap[item.type];
  if (!driver) return false;
  return driver(item.spec);
}

export function scanAll(items, { topicsRoot, platform = 'mac' } = {}) {
  const results = new Map();
  for (const item of items) {
    const key = `${item.topic}/${item.name}`;
    results.set(key, checkItem(item, { topicsRoot, platform }));
  }
  return results;
}
