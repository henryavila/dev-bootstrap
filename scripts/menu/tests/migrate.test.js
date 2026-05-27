import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { readSelections, readParams } from '../lib/core/selections-io.js';

describe('migrate (unit logic)', () => {
  it('parses INCLUDE_* vars from config.env format', () => {
    const content = [
      'INCLUDE_DOCKER=1',
      'INCLUDE_WEBSTACK=1',
      'INCLUDE_AI_TOOLS=0',
      'PHP_VERSIONS="8.4 8.5"',
      'CODE_DIR=/Volumes/External/code',
      '# Comment line',
      '',
      'GIT_NAME=Henry',
    ].join('\n');

    const vars = {};
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eq = trimmed.indexOf('=');
      if (eq < 0) continue;
      const key = trimmed.slice(0, eq);
      let val = trimmed.slice(eq + 1);
      val = val.replace(/^["']|["']$/g, '');
      vars[key] = val;
    }

    assert.strictEqual(vars.INCLUDE_DOCKER, '1');
    assert.strictEqual(vars.INCLUDE_WEBSTACK, '1');
    assert.strictEqual(vars.INCLUDE_AI_TOOLS, '0');
    assert.strictEqual(vars.PHP_VERSIONS, '8.4 8.5');
    assert.strictEqual(vars.CODE_DIR, '/Volumes/External/code');
    assert.strictEqual(vars.GIT_NAME, 'Henry');
  });

  it('maps INCLUDE_* to topic names correctly', () => {
    const INCLUDE_MAP = {
      INCLUDE_DOCKER: '45-docker',
      INCLUDE_WEBSTACK: '60-web-stack',
      INCLUDE_LARAVEL: '60-web-stack',
      INCLUDE_REMOTE: '70-remote-access',
      INCLUDE_AI_TOOLS: '82-ai-tools',
      INCLUDE_CODE_SERVER: '85-code-server',
      INCLUDE_EDITOR: '90-editor',
      INCLUDE_IDENTITY: '95-dotfiles-personal',
    };

    const vars = { INCLUDE_DOCKER: '1', INCLUDE_WEBSTACK: '1' };
    const enabled = new Set();
    for (const [envVar, topic] of Object.entries(INCLUDE_MAP)) {
      if (vars[envVar] === '1') enabled.add(topic);
    }

    assert.ok(enabled.has('45-docker'));
    assert.ok(enabled.has('60-web-stack'));
    assert.ok(!enabled.has('82-ai-tools'));
  });

  it('handles INCLUDE_LARAVEL as alias for 60-web-stack', () => {
    const INCLUDE_MAP = {
      INCLUDE_LARAVEL: '60-web-stack',
      INCLUDE_WEBSTACK: '60-web-stack',
    };

    const vars = { INCLUDE_LARAVEL: '1' };
    const enabled = new Set();
    for (const [envVar, topic] of Object.entries(INCLUDE_MAP)) {
      if (vars[envVar] === '1') enabled.add(topic);
    }

    assert.ok(enabled.has('60-web-stack'));
  });

  it('extracts params from old config', () => {
    const vars = {
      PHP_VERSIONS: '8.4 8.5',
      PHP_DEFAULT: '8.5',
      CODE_DIR: '/home/user/code',
      GIT_NAME: 'Test',
      GIT_EMAIL: 'test@example.com',
    };

    const params = {};
    if (vars.PHP_VERSIONS) params.MESH_PHP_VERSIONS = vars.PHP_VERSIONS;
    if (vars.PHP_DEFAULT) params.MESH_PHP_DEFAULT = vars.PHP_DEFAULT;
    if (vars.CODE_DIR) params.MESH_CODE_DIR = vars.CODE_DIR;
    if (vars.GIT_NAME) params.GIT_NAME = vars.GIT_NAME;
    if (vars.GIT_EMAIL) params.GIT_EMAIL = vars.GIT_EMAIL;

    assert.strictEqual(params.MESH_PHP_VERSIONS, '8.4 8.5');
    assert.strictEqual(params.MESH_PHP_DEFAULT, '8.5');
    assert.strictEqual(params.MESH_CODE_DIR, '/home/user/code');
  });
});
