import * as p from '@clack/prompts';
import { isCancel } from '@clack/core';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

export async function promptParams(selectedTopics, currentParams = {}, { topicsRoot } = {}) {
  const params = { ...currentParams };

  if (selectedTopics.includes('60-web-stack')) {
    const phpVersions = await promptPhpVersions(params, topicsRoot);
    if (phpVersions === null) return null;
    Object.assign(params, phpVersions);
  }

  if (selectedTopics.includes('05-identity') || selectedTopics.includes('95-dotfiles-personal')) {
    const identity = await promptIdentity(params);
    if (identity === null) return null;
    Object.assign(params, identity);
  }

  return params;
}

async function promptPhpVersions(params, topicsRoot) {
  const available = loadPhpVersions(topicsRoot);
  const current = (params.MESH_PHP_VERSIONS ?? '').split(/\s+/).filter(Boolean);

  const versions = await p.multiselect({
    message: 'Select PHP versions to install',
    options: available.map((v) => ({
      value: v,
      label: `PHP ${v}`,
    })),
    initialValues: current.length > 0 ? current : available.slice(-2),
    required: true,
  });
  if (isCancel(versions)) return null;

  const defaultVersion =
    versions.length === 1
      ? versions[0]
      : await p.select({
          message: 'Default PHP version',
          options: versions.map((v) => ({ value: v, label: `PHP ${v}` })),
          initialValue: params.MESH_PHP_DEFAULT ?? versions[versions.length - 1],
        });
  if (isCancel(defaultVersion)) return null;

  return {
    MESH_PHP_VERSIONS: versions.join(' '),
    MESH_PHP_DEFAULT: defaultVersion,
  };
}

function loadPhpVersions(topicsRoot) {
  if (!topicsRoot) return ['8.3', '8.4', '8.5'];
  const versionsFile = join(topicsRoot, '10-languages', 'data', 'php-versions.conf');
  if (!existsSync(versionsFile)) return ['8.3', '8.4', '8.5'];
  return readFileSync(versionsFile, 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'));
}

async function promptIdentity(params) {
  const result = {};

  if (!params.GIT_NAME) {
    const name = await p.text({
      message: 'Git author name',
      placeholder: 'Your Name',
    });
    if (isCancel(name)) return null;
    if (name) result.GIT_NAME = name;
  }

  if (!params.GIT_EMAIL) {
    const email = await p.text({
      message: 'Git author email',
      placeholder: 'you@example.com',
    });
    if (isCancel(email)) return null;
    if (email) result.GIT_EMAIL = email;
  }

  return result;
}
