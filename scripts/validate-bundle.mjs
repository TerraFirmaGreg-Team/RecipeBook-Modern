#!/usr/bin/env node
/**
 * Validate site/bundles/* using emi-recipe-renderer contract.
 * With no args: reads site/bundles.json and validates each installed bundle.
 * With one arg: validates that directory only.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { printValidationOk, validateBundleRoot } from 'emi-recipe-renderer/validate';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const siteDir = path.join(scriptDir, '../site');
const bundlesJsonPath = path.join(siteDir, 'bundles.json');

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function runValidate(bundleRoot) {
  try {
    const result = validateBundleRoot(bundleRoot);
    printValidationOk(result);
  } catch (err) {
    fail(err.message || String(err));
  }
}

const argRoot = process.argv[2] || process.env.EMI_BUNDLE_ROOT;

if (argRoot) {
  runValidate(path.resolve(argRoot));
  process.exit(0);
}

if (!fs.existsSync(bundlesJsonPath)) {
  fail(`missing ${bundlesJsonPath}; create it or pass a bundle directory as argv[2]`);
}

const cfg = readJson(bundlesJsonPath);
const ids = cfg.bundles;
if (!Array.isArray(ids) || ids.length === 0) {
  fail('bundles.json: "bundles" must be a non-empty array of ids');
}

let validated = 0;
const skipped = [];

for (const id of ids) {
  const bundleRoot = path.join(siteDir, 'bundles', id);
  if (!fs.existsSync(path.join(bundleRoot, 'bundle.json'))) {
    skipped.push(id);
    console.warn(`SKIP: "${id}" (not installed under site/bundles/${id}/)`);
    continue;
  }
  runValidate(bundleRoot);
  validated += 1;
}

const defaultId = cfg.default;
if (defaultId && !fs.existsSync(path.join(siteDir, 'bundles', defaultId, 'bundle.json'))) {
  fail(`default bundle "${defaultId}" is not installed. Run: npm run link -- --id ${defaultId} <export-dir>`);
}

if (validated === 0) {
  fail('no bundles installed; link at least one id from bundles.json');
}

console.log(`Validated ${validated} bundle(s).`);
if (skipped.length) {
  console.log(`Skipped ${skipped.length} (not installed): ${skipped.join(', ')}`);
}
