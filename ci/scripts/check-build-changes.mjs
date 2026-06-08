#!/usr/bin/env node
import { readFileSync, existsSync, appendFileSync } from 'node:fs';

import { EXPORT_VERSION_KEYS, VERSION_KEYS, versionsFromArgv } from '../lib/build-json.mjs';

const args = process.argv.slice(2);
if (args.length < 7) {
  console.error('usage: check-build-changes.mjs <recordedPath> <versions...6>');
  process.exit(1);
}

const [recordedPath, ...versionArgs] = args;
const forceExport = process.env.FORCE_EXPORT === 'true';
const current = versionsFromArgv(versionArgs);

/** @type {Record<string, unknown>} */
let recorded = {};
if (existsSync(recordedPath)) {
  try {
    recorded = JSON.parse(readFileSync(recordedPath, 'utf8'));
  } catch {
    recorded = {};
  }
}

const differs = (key) => String(recorded[key] ?? '') !== String(current[key] ?? '');
const hasRecorded = Object.keys(recorded).length > 0;
let exportNeeded = !hasRecorded || EXPORT_VERSION_KEYS.some(differs);
if (forceExport) exportNeeded = true;
const deployNeeded = !hasRecorded || VERSION_KEYS.some(differs) || forceExport;

const lines = [
  `export_needed=${exportNeeded}`,
  `deploy_needed=${deployNeeded}`,
  `changed=${deployNeeded}`,
];
for (const key of VERSION_KEYS) {
  if (differs(key)) {
    lines.push(`changed_${key.replace(/[^a-z0-9]+/gi, '_')}=true`);
  }
}

const payload = `${lines.join('\n')}\n`;
const outPath = process.env.GITHUB_OUTPUT;
if (outPath) {
  appendFileSync(outPath, payload);
} else {
  process.stdout.write(payload);
}

if (deployNeeded) {
  console.error('::group::build.json diff (published site)');
  for (const key of VERSION_KEYS) {
    console.error(`${key}: recorded=${recorded[key] ?? '<none>'} current=${current[key]}`);
  }
  console.error('::endgroup::');
} else {
  console.error('Published build.json matches resolved versions — nothing to do');
}
