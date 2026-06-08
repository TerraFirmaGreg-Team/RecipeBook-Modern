#!/usr/bin/env node
import { readFileSync, existsSync } from 'node:fs';

const langCfg = process.argv[2];
if (!langCfg) {
  console.error('usage: resolve-export-languages.mjs <language.json>');
  process.exit(1);
}

if (!existsSync(langCfg)) {
  process.stdout.write('en_us,zh_cn');
  process.exit(0);
}

const cfg = JSON.parse(readFileSync(langCfg, 'utf8'));
const arr = Array.isArray(cfg.enabledLocales) ? cfg.enabledLocales : [];
const norm = [
  ...new Set(
    arr
      .map((s) => String(s || '').trim().toLowerCase().replace(/-/g, '_'))
      .filter(Boolean),
  ),
];
process.stdout.write((norm.length ? norm : ['en_us', 'zh_cn']).join(','));
