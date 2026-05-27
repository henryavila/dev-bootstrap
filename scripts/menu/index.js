#!/usr/bin/env node
import { runWizard } from './lib/wizard.js';

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');

const result = await runWizard({ dryRun });
if (result) {
  process.exit(0);
} else {
  process.exit(1);
}
