import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { readFileSync, existsSync } from 'node:fs';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';

const ENGINE_DIR = join(dirname(new URL(import.meta.url).pathname), '..', '..', '..', 'lib');

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

function checkCustomScript(scriptPath) {
  if (!existsSync(scriptPath)) return false;
  try {
    const content = readFileSync(scriptPath, 'utf8');
    if (!/^check\s*\(\)/m.test(content)) return false;

    const brewBin = process.env.HOMEBREW_PREFIX
      ? `${process.env.HOMEBREW_PREFIX}/bin/brew`
      : '/opt/homebrew/bin/brew';
    const result = execSync(
      `bash -c '
        set +e
        sudo() { return 1; }
        export -f sudo
        source "${ENGINE_DIR}/log.sh" 2>/dev/null
        source "${ENGINE_DIR}/env.sh" 2>/dev/null
        BREW_BIN="${brewBin}"
        source "${scriptPath}" 2>/dev/null
        if declare -f check >/dev/null 2>&1; then
          check && echo __INSTALLED__ || echo __NOT_INSTALLED__
        else
          echo __NO_CHECK__
        fi
      '`,
      { stdio: ['pipe', 'pipe', 'pipe'], timeout: 5_000, encoding: 'utf8' },
    );
    return result.includes('__INSTALLED__');
  } catch {
    return false;
  }
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

function scanAllSync(items, { topicsRoot, platform = 'mac' } = {}) {
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

export async function scanAll(items, { topicsRoot, platform = 'mac' } = {}) {
  const thisFile = new URL(import.meta.url).pathname;
  return new Promise((resolve, reject) => {
    const worker = new Worker(thisFile, {
      workerData: {
        items: items.map((i) => ({ ...i })),
        topicsRoot,
        platform,
      },
    });
    worker.on('message', (entries) => {
      resolve(new Map(entries));
    });
    worker.on('error', reject);
    worker.on('exit', (code) => {
      if (code !== 0) reject(new Error(`Scanner exited with code ${code}`));
    });
  });
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

if (!isMainThread) {
  const { items, topicsRoot, platform } = workerData;
  const results = scanAllSync(items, { topicsRoot, platform });
  parentPort.postMessage([...results.entries()]);
}
