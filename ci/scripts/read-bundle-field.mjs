#!/usr/bin/env node
import { readFileSync } from 'node:fs';

const [bundleJsonPath, field] = process.argv.slice(2);
if (!bundleJsonPath || !field) {
  console.error('usage: read-bundle-field.mjs <bundle.json> <schema|imageScale>');
  process.exit(1);
}

const bundle = JSON.parse(readFileSync(bundleJsonPath, 'utf8'));
if (field === 'schema') {
  process.stdout.write(String(bundle.schema ?? ''));
} else if (field === 'imageScale') {
  process.stdout.write(String(bundle.imageScale ?? ''));
} else {
  console.error(`::error::unsupported field: ${field}`);
  process.exit(1);
}
