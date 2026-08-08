#!/usr/bin/env node
/**
 * Locale linter — validates every translation file under src/locales/:
 *
 *   1. Every file listed in meta.json has a real {code}.json file
 *    2. Every translation file parses as JSON
 *    3. Every key is also in the source locale (en.json)
 *    4. Every source key's placeholders ({name}, {count}, ...) are
 *       preserved in translations
 *
 * Reports coverage per locale and exits non-zero on any hard error.
 * Missing translations are a warning, not an error — they fall back
 * to English at runtime.
 *
 * Run: node scripts/check-i18n.mjs
 */
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const localesDir = join(scriptDir, '..', 'src', 'locales');

const errors = [];
const warnings = [];

function loadJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    errors.push(`${path}: invalid JSON (${e.message})`);
    return null;
  }
}

const meta = loadJson(join(localesDir, 'meta.json'));
if (!Array.isArray(meta)) {
  errors.push('meta.json: must be an array of locale metadata');
  report();
  process.exit(1);
}

const source = loadJson(join(localesDir, 'en.json'));
if (!source || typeof source !== 'object') {
  errors.push('en.json: missing or not an object');
  report();
  process.exit(1);
}

const sourceKeys = Object.keys(source);
const placeholderRegex = /\{(\w+)\}/g;

// CLDR plural categories. Plural strings live as sibling keys with a
// category suffix (e.g. "feed.replies.one"/".other"); a target locale may
// add categories the source doesn't need (Arabic uses zero/two/few/many),
// so those are valid as long as the source defines the plural set.
const PLURAL_CATEGORIES = new Set(['zero', 'one', 'two', 'few', 'many', 'other']);

// base -> Set(categories present in source), for every source plural key.
const sourcePluralBases = new Map();
for (const k of sourceKeys) {
  const dot = k.lastIndexOf('.');
  if (dot === -1) continue;
  const suffix = k.slice(dot + 1);
  if (!PLURAL_CATEGORIES.has(suffix)) continue;
  const base = k.slice(0, dot);
  if (!sourcePluralBases.has(base)) sourcePluralBases.set(base, new Set());
  sourcePluralBases.get(base).add(suffix);
}

// A target key is a legit plural variant if its base has a plural set in
// source. Returns the source sibling to compare placeholders against, or
// null if this key is not a valid plural variant.
function pluralSourceSibling(key) {
  const dot = key.lastIndexOf('.');
  if (dot === -1) return null;
  const suffix = key.slice(dot + 1);
  if (!PLURAL_CATEGORIES.has(suffix)) return null;
  const base = key.slice(0, dot);
  if (!sourcePluralBases.has(base)) return null;
  if (source[`${base}.other`] != null) return `${base}.other`;
  if (source[`${base}.one`] != null) return `${base}.one`;
  return key; // base has a plural set but no other/one; skip placeholder check
}

function placeholdersOf(value) {
  if (typeof value !== 'string') return new Set();
  const out = new Set();
  for (const match of value.matchAll(placeholderRegex)) out.add(match[1]);
  return out;
}

const filesOnDisk = new Set(
  readdirSync(localesDir)
    .filter((f) => f.endsWith('.json') && f !== 'meta.json')
    .map((f) => f.replace(/\.json$/, '')),
);

for (const entry of meta) {
  const code = entry.code;
  if (!filesOnDisk.has(code)) {
    errors.push(`meta.json lists "${code}" but src/locales/${code}.json is missing`);
    continue;
  }

  const data = loadJson(join(localesDir, `${code}.json`));
  if (!data || typeof data !== 'object') continue;

  const translatedKeys = Object.keys(data);
  const present = translatedKeys.filter((k) => sourceKeys.includes(k));
  const extraneous = translatedKeys.filter(
    (k) => !sourceKeys.includes(k) && pluralSourceSibling(k) === null,
  );
  const pluralVariants = translatedKeys.filter(
    (k) => !sourceKeys.includes(k) && pluralSourceSibling(k) !== null,
  );
  const missing = sourceKeys.filter((k) => !translatedKeys.includes(k));
  const coverage = sourceKeys.length === 0 ? 100 : Math.round((present.length / sourceKeys.length) * 100);

  for (const k of extraneous) {
    errors.push(`${code}.json: key "${k}" is not in en.json (stale or typo'd)`);
  }

  for (const k of present) {
    const srcPlaceholders = placeholdersOf(source[k]);
    const dstPlaceholders = placeholdersOf(data[k]);
    for (const p of srcPlaceholders) {
      if (!dstPlaceholders.has(p)) {
        errors.push(`${code}.json: key "${k}" missing placeholder {${p}}`);
      }
    }
  }

  // Plural variants (e.g. Arabic ".few") check placeholders against their
  // source sibling (".other"). {count} is expected but not required — some
  // categories read naturally without echoing the number.
  for (const k of pluralVariants) {
    const sibling = pluralSourceSibling(k);
    const srcPlaceholders = placeholdersOf(source[sibling]);
    const dstPlaceholders = placeholdersOf(data[k]);
    for (const p of srcPlaceholders) {
      if (p !== 'count' && !dstPlaceholders.has(p)) {
        errors.push(`${code}.json: plural key "${k}" missing placeholder {${p}}`);
      }
    }
  }

  if (code === 'en') continue;
  if (missing.length > 0) {
    warnings.push(`${code}: ${coverage}% coverage (${missing.length} missing)`);
  } else {
    warnings.push(`${code}: 100% coverage`);
  }
}

for (const file of filesOnDisk) {
  if (!meta.some((m) => m.code === file)) {
    errors.push(`src/locales/${file}.json exists but is not listed in meta.json`);
  }
}

function report() {
  if (warnings.length) {
    console.log('i18n coverage:');
    for (const w of warnings) console.log('  ' + w);
  }
  if (errors.length) {
    console.error('\ni18n errors:');
    for (const e of errors) console.error('  ' + e);
  }
}

report();
process.exit(errors.length > 0 ? 1 : 0);
