#!/usr/bin/env node
/**
 * Link (symlink) or copy an EMI export directory into site/bundles/<id> and register id in site/bundles.json.
 *
 * Usage:
 *   node scripts/install-bundle.mjs link --id <bundleId> <export-dir>
 *   node scripts/install-bundle.mjs copy --id <bundleId> <export-dir>
 *
 * npm:
 *   npm run link -- --id vanilla /path/to/emi
 *   npm run copy -- --id tfg-0.12.8 /path/to/emi
 */
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const siteDir = path.join(root, 'site');
const bundlesDir = path.join(siteDir, 'bundles');
const bundlesJsonPath = path.join(siteDir, 'bundles.json');

function usage() {
  console.error(`Usage:
  node scripts/install-bundle.mjs link --id <bundleId> <export-dir>
  node scripts/install-bundle.mjs copy --id <bundleId> <export-dir>

Examples:
  npm run link -- --id vanilla /path/to/emi
  npm run copy -- --id field-guide-modern /path/to/export`);
}

function readBundlesConfig() {
  if (!existsSync(bundlesJsonPath)) {
    return { default: null, bundles: [] };
  }
  return JSON.parse(readFileSync(bundlesJsonPath, 'utf8'));
}

function writeBundlesConfig(cfg) {
  const bundles = [];
  const seen = new Set();
  for (const id of cfg.bundles || []) {
    if (typeof id !== 'string' || !id.trim()) continue;
    if (seen.has(id)) continue;
    seen.add(id);
    bundles.push(id);
  }
  cfg.bundles = bundles;
  if (!cfg.default && bundles.length) cfg.default = bundles[0];
  writeFileSync(bundlesJsonPath, `${JSON.stringify(cfg, null, 2)}\n`, 'utf8');
}

function isBundleInstalled(bundleId) {
  return existsSync(path.join(bundlesDir, bundleId, 'bundle.json'));
}

function mergeBundleId(cfg, id, { setDefault = false } = {}) {
  if (!Array.isArray(cfg.bundles)) cfg.bundles = [];
  if (!cfg.bundles.includes(id)) cfg.bundles.push(id);
  const defaultMissing = !cfg.default || !isBundleInstalled(cfg.default);
  if (setDefault || defaultMissing) {
    cfg.default = id;
  }
  writeBundlesConfig(cfg);
}

/** True when source and dest are the same bundle dir (avoids rm+copy deleting in-place exports). */
function sameBundleDir(sourceDir, destDir) {
  const src = path.resolve(sourceDir);
  const dst = path.resolve(destDir);
  if (src === dst) return true;
  if (!existsSync(dst)) return false;
  try {
    return realpathSync(src) === realpathSync(dst);
  } catch {
    return false;
  }
}

const args = process.argv.slice(2);
const op = args[0];
if (op !== 'link' && op !== 'copy') {
  usage();
  process.exit(1);
}

let id;
let source;
const rest = args.slice(1);
if (rest[0] === '--id' && rest[1]) {
  id = rest[1];
  source = rest[2];
} else {
  id = rest[0];
  source = rest[1];
}

if (!id || !source) {
  usage();
  process.exit(1);
}

if (id.includes('/') || id.includes('\\') || id === '.' || id === '..') {
  console.error('bundle id must be a single path segment (no slashes).');
  process.exit(1);
}

const absSource = path.resolve(source);
if (!existsSync(path.join(absSource, 'bundle.json'))) {
  console.error(`Export directory missing bundle.json: ${absSource}`);
  process.exit(1);
}

mkdirSync(bundlesDir, { recursive: true });
const dest = path.join(bundlesDir, id);

if (sameBundleDir(absSource, dest)) {
  if (op === 'copy') {
    writeBundlesConfig({ default: id, bundles: [id] });
  } else {
    mergeBundleId(readBundlesConfig(), id);
  }
  console.log(`OK: bundle "${id}" already at site/bundles/${id} (same path, skipped ${op})`);
  console.log(`Updated: site/bundles.json`);
  process.exit(0);
}

if (existsSync(dest)) {
  rmSync(dest, { recursive: true, force: true });
}

if (op === 'link') {
  let target = absSource;
  try {
    const rel = path.relative(bundlesDir, absSource);
    if (rel && !rel.startsWith('..') && !path.isAbsolute(rel)) {
      target = rel;
    }
  } catch {
    // keep absolute
  }
  symlinkSync(target, dest, 'dir');
} else {
  cpSync(absSource, dest, { recursive: true });
}

if (op === 'copy') {
  writeBundlesConfig({ default: id, bundles: [id] });
} else {
  mergeBundleId(readBundlesConfig(), id);
}

console.log(`OK: ${op} bundle "${id}" -> site/bundles/${id}`);
console.log(`Updated: site/bundles.json`);
