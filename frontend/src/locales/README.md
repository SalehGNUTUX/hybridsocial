# Translations

All UI strings live in flat-key JSON files next to this README, one per locale.
`en.json` is the canonical source. Every other locale falls back to English at
runtime for any missing key, so an empty `{}` is a perfectly valid locale file.

## Layout

- `en.json` — source of truth, flat-key JSON (`"nav.home": "Home"`)
- `meta.json` — array of `{code, name, nativeName, rtl?}` entries shown in the
  language picker. A locale must appear in both `meta.json` and have a
  `{code}.json` file — `npm run check:i18n` verifies this.
- `{code}.json` — translated strings. Missing keys fall back to English.

## Adding strings

1. Add the key to `en.json`.
2. Run `npm run check:i18n` from `frontend/` to confirm nothing else is stale.
3. Commit. Translators will pick up the new key the next time Weblate polls.

## Plurals

Counting strings must use plural variants, because languages disagree on how
many forms they need (English has 2, Arabic has 6). Store one key per CLDR
category as sibling keys with a suffix, and call `t()` with a numeric `count`:

```jsonc
// en.json — English only needs one/other
"feed.replies.one":   "{count} reply",
"feed.replies.other": "{count} replies"
```
```jsonc
// ar.json — Arabic uses zero/one/two/few/many/other
"feed.replies.zero":  "لا ردود",
"feed.replies.one":   "رد واحد",
"feed.replies.two":   "ردان",
"feed.replies.few":   "{count} ردود",
"feed.replies.many":  "{count} ردًا",
"feed.replies.other": "{count} رد"
```
```ts
t('feed.replies', { count: n }) // picks the category via Intl.PluralRules
```

`t()` resolves the active locale's category (falling back category → `.other`
→ English). The linter accepts categories a target adds beyond the source, as
long as the source defines the plural set (an `.other` or `.one` sibling).
`{count}` is optional in a variant (e.g. Arabic `two` reads naturally without
echoing the number).

## Adding a locale

1. Add a `{code}.json` file (empty `{}` is fine).
2. Add a metadata entry to `meta.json`.
3. Run `npm run check:i18n`.

## Connecting to Weblate

The repo ships with a `.weblate` config at the root describing this layout. To
connect it to [Hosted Weblate](https://hosted.weblate.org/):

1. Create a new project on Hosted Weblate.
2. Add a component, point it at this Git repo, and pick branch `main`.
3. Weblate will auto-detect the file format from `.weblate` (JSON, source file
   `frontend/src/locales/en.json`, filemask `frontend/src/locales/*.json`).
4. Configure a push-back branch (e.g. `weblate-translations`) — Weblate will
   open pull requests with translator edits.

For a self-hosted Weblate instance, use the same component settings.

## Runtime behavior

See `frontend/src/lib/utils/i18n.ts`:

- `t("key")` — translate, fall back to English, then to the key itself.
- `tError("backend.error_code")` — translate a backend error key with a small
  hardcoded fallback map for errors that can fire before i18n has loaded.
- Placeholders use `{name}` syntax: `t("greeting", { name: "Ahmad" })`.
- RTL auto-detected from `meta.json` (`rtl: true`) or a hardcoded list of RTL
  language codes.

## CI

`npm run check:i18n` exits non-zero if:

- a `{code}.json` file is invalid JSON
- a locale appears in `meta.json` but the file is missing (or vice versa)
- a translation contains a key that doesn't exist in `en.json`
- a translation is missing a placeholder (`{name}`, `{count}`) that exists in
  the English source

Missing translations are reported as warnings (coverage %), not errors — they
fall back to English at runtime.
