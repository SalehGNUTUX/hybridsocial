# Translations & Weblate

HybridSocial's UI strings live in flat-key JSON under
`frontend/src/locales/`, one file per locale, with `en.json` as the canonical
source. The runtime loader (`frontend/src/lib/utils/i18n.ts`) falls back to
English for any missing key, so a partially-translated locale is always safe.

This doc is the runbook for connecting the repo to
[Hosted Weblate](https://hosted.weblate.org/) so translator edits land as pull
requests. For the file layout and the `t()` API, see
`frontend/src/locales/README.md`.

## Prerequisites

Weblate is only worth connecting once `en.json` is the real source of truth,
i.e. UI strings have been extracted from components into `t()` calls. Until
then Weblate can only translate the handful of keys that exist.

Check current coverage any time:

```bash
cd frontend && npm run check:i18n
```

## One-time setup on Hosted Weblate

The project is AGPLv3, so it qualifies for free hosting on
hosted.weblate.org under the [libre plan](https://weblate.org/hosting/).

1. Request a project on hosted.weblate.org (libre hosting).
2. **Add a component** and point it at this repo. Weblate reads the root
   `.weblate` file and auto-fills the layout:
   - Repository: `https://github.com/qfiber/hybridsocial`
   - Branch: `main`
   - File mask: `frontend/src/locales/*.json`
   - Monolingual base / template: `frontend/src/locales/en.json`
   - File format: **JSON file** (flat). Do **not** pick "JSON nested
     structure" — our keys are flat dotted strings (`"nav.home"`), and the
     nested format would split on the dot and rewrite the files, breaking the
     loader. The `.weblate` file pins `file_format = "json"` for this reason.
3. **Authorize write-back.** Add Weblate's SSH deploy key to the GitHub repo
   (Settings → Deploy keys, allow write), or install the Weblate GitHub App.
4. **Push-back branch.** Set the push branch to `weblate-translations` (not
   `main`) so Weblate opens PRs instead of committing straight to `main`.
   Enable "Automatically receive changes" via the GitHub webhook so pulls are
   near-realtime.
5. **New languages.** `.weblate` sets `new_lang = "add"`, so translators can
   start a new locale from the UI; it creates `frontend/src/locales/{code}.json`.
   Remember to also add the `{code}` to `meta.json` (with `rtl: true` for
   right-to-left languages) or it won't appear in the app's language picker.

## The CI gate applies to Weblate PRs too

`node frontend/scripts/check-i18n.mjs` runs on every PR, including the ones
Weblate opens. It fails the build if a translation:

- isn't valid JSON,
- contains a key absent from `en.json` (stale/typo'd), or
- drops a placeholder (`{name}`, `{count}`, ...) present in the source.

Plural-category variants a locale adds beyond the source (Arabic
`zero/two/few/many`) are accepted as long as the source defines the plural set.
See the Plurals section of `frontend/src/locales/README.md`.

## Self-hosting instead

To run Weblate next to the existing stack, use the official
`weblate/weblate` Docker image with its Postgres + Redis services and point a
component at this repo with the same settings above. Same `.weblate`, same CI
gate; you own the backups.
