# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

HybridSocial is a decentralized social platform. It uses **ActivityPub strictly as a
federation transport** — the internal data model is optimized for features (groups, pages,
feeds, ranking, moderation, DMs) and AP objects are *projections* of it, not the source of
truth. The backend is authoritative for all permissions and visibility; the frontend is a
pure API client. Almost everything is **database-backed and runtime-configurable** via the
admin panel — env vars are for infrastructure only, and there are no hardcoded limits.

- `backend/` — Elixir/Phoenix JSON API + the full ActivityPub federation stack (no LiveView UI)
- `frontend/` — SvelteKit web app (Svelte 5 runes), a Mastodon-compatible REST client
- infra — `Caddyfile` + `caddy/` (Coraza WAF), `crowdsec/`, `docker/`, `docker-compose*.yml`, `federation-test/`
- `docs/SPEC.md` — the authoritative product/architecture spec (32 sections)

## Commands

```bash
# Backend (from backend/)
mix deps.get
mix ecto.setup                 # create + migrate + seed
mix phx.server                 # dev API server
mix test                       # full suite
mix test test/path/to/foo_test.exs          # a single file
mix test test/path/to/foo_test.exs:42       # a single test by line
mix test --failed              # rerun last failures
mix precommit                  # REQUIRED before finishing: compile --warnings-as-errors,
                               # deps.unlock --unused, format, test

# Frontend (from frontend/)
npm ci
npm run dev
npm run build
npm run check                  # svelte-kit sync + svelte-check (type/a11y)
node scripts/check-i18n.mjs    # locale-file linter (a CI gate — see below)

# Full stack
docker compose up
```

## CI gates (a PR must pass all of these — run locally first)

Backend (Elixir 1.18 / OTP 28, against Postgres 17 + Valkey 8):
`mix compile --warnings-as-errors` · `mix format --check-formatted` · `mix credo --strict`
· `mix test --partitions 4` · `mix sobelow --config` · `mix deps.audit`.
Frontend: `node scripts/check-i18n.mjs`. (CI does not build the frontend beyond the i18n
check, but run `npm run check` locally — it must report 0 errors.) `mix precommit` covers
the core backend gates in one shot.

## Backend architecture

Two OTP trees under `backend/lib/`:
- `hybridsocial/` — business logic as Phoenix **contexts**, each a `<name>.ex` facade over a
  `<name>/` directory. Key ones: `accounts`, `auth` (sessions, tokens, OAuth, plus
  registration/login hardening — email-confirmation gate via the
  `require_confirmed_email` plug, proof-of-work nonce, and captcha), `social` (posts, boosts, polls, follows,
  blocks/mutes, lists, bookmarks, hashtags, stories, reactions), `messaging` (DMs, federated
  as Statuses), `media` (uploads, transcoding, `antivirus`), `feeds`/`timelines`, `trending`,
  `search`, `notifications`, `streaming` (real-time), `nats`, `moderation`, `admin`, `groups`,
  `pages`, `portability` (import/export), and monetization (`payments`/`premium`/`badges`).
- `hybridsocial_web/` — `router.ex`, `endpoint.ex`, `controllers/` (`api/`, `federation/`),
  `serializers/`, `channels/`, `plugs/`.

**Federation** (`hybridsocial/federation/`) is the deepest subsystem:
- Inbound: `inbox.ex` — the first step is always containment/origin verification
  (`containment.ex`) before anything is trusted; then Follow/Accept, relay follows
  (`relays.ex`), poll-vote Updates, and remote actor/object resolution with an
  unsigned→signed→Mastodon-API fallback.
- Outbound: `publisher.ex` fan-out → `delivery.ex`/`delivery_worker.ex`, guarded by a
  per-domain `circuit_breaker.ex` (trips after 5 consecutive hard failures; soft/HTTP errors
  don't trip; escalating reopen backoff), with `dead_letters.ex` + `dedup.ex`.
- Serialization: `actor_serializer.ex`, `outbox_serializer.ex`, `activity_builder.ex`.
- Security/discovery: `http_signature.ex`, `signed_fetch.ex`, `webfinger.ex`, `node_info.ex`,
  `instance_actor.ex`, and MRF message-rewrite filters in `mrf/`.

Event flow uses **NATS JetStream** for durable events (post.created, reaction.created, …) that
workers consume; Phoenix PubSub is kept for ephemeral real-time (SSE feeds, WebSocket DMs).

## Permissions, roles & tiers

- **Authorization is server-side, in the context.** A mutation checks the actor against a role
  ladder via a `require_role(scope_id, actor_id, allowed_roles)` helper returning `{:ok, role}`
  (the actor's role, or `:staff` for an instance moderator via `Auth.RBAC`) or
  `{:error, :forbidden}`. Groups is the reference model: roles `[:member, :moderator, :admin,
  :owner]` with `@moderate_roles`/`@manage_roles`/`@destroy_roles` tiers. The authoritative owner
  is the `owner` membership row (`created_by` is immutable but is *not* the permission) — guard
  the owner role explicitly so an `admin` can't grant or seize it. Membership role lookups filter
  on `status == :approved`.
- **Per-tier limits** come from `TierLimits.limits_for(identity)` (`char_limit`, `media_per_post`,
  `markdown` level, …). A post's `content_html` is rendered server-side from raw `content` with
  the tier's markdown level (`sanitize_post_content(content, level)`); the client may only opt
  *down* (`markdown: false`). Any path that re-renders a body — **create and edit both** — must
  apply the tier level, or it silently strips the post's markdown.
- **Enum fields are strict `Ecto.Enum`s — the client must send the exact atom strings.** A group's
  `visibility` is `[:public, :private, :local_only]` and `join_policy` is
  `[:open, :screening, :approval, :invite_only]` (`groups/group.ex`); an out-of-set value fails
  the changeset with a 422, so every frontend `<option value>`/type union must match byte-for-byte
  (a drifted `secret`/`invite` silently breaks saving).
- **Pages are their own `organization` identities**, not a side table: a post's `page_id` *is* that
  identity's id, and a page authors posts under it. Edit authority runs its own ladder in
  `pages.ex` — `can_edit?` (parent/org owner, admin, editor) ⊇ what `can_moderate?` adds
  (moderator), while `can_manage?` (owner/admin only) gates role grants and settings. Gate any
  "act as / edit the page" path on the matching predicate; instance staff don't implicitly get it.

## Frontend architecture

SvelteKit 2 + **Svelte 5 (runes mode is enforced)**; `adapter-node` for production
(`svelte.config.node.js`). Under `frontend/src/`:
- `routes/` — grouped layouts `(app)`, `(auth)`, `legal`, `admin`.
- `lib/api/` — `client.ts` is the core fetch wrapper; ~28 typed resource modules call it;
  `types.ts` is the shared contract (Mastodon-compatible REST).
- `lib/stores/` — ~22 stores. Note `theme.ts` (see below) and `i18n.ts`.
- `lib/components/` — organized by domain (`ui/`, `layout/`, `feed/`, `post/`, `dm/`, `admin/`).

Cross-cutting systems worth knowing before editing UI:
- **Theming**: color tokens live in `app.css` (`:root` light, `:root[data-theme='dark']` dark);
  `theme.ts` `applyTheme()`/`render()` set them at runtime, a no-FOUC boot script in `app.html`
  sets `data-theme` before first paint, and `resolvedMode` exposes the active light/dark. Only
  *brand* hues are derived for dark; the rest come from the designed dark ramp.
- **i18n / RTL**: `i18n.ts` exposes a `locale` store; `+layout.svelte` sets `<html dir/lang>`
  from it. CSS uses **logical properties** (`margin-inline`, `inset-inline`, `text-align:start`)
  so layouts mirror automatically — prefer these over physical `left/right` in new code.
- **Optimistic posting**: `PostComposer.svelte` dispatches a `new-post` CustomEvent to show the
  post immediately, then `post-replace` once the server returns the real one. Toasts come from
  `stores/toast.ts` (`addToast`).
- **PWA**: `static/sw.js` (service worker, push) + `static/manifest.json`.

## Testing

- Backend: `use Hybridsocial.DataCase, async: true`; a `create_user("handle", "email")` helper
  builds identity fixtures and `errors_on(changeset)` inspects validation. Put an authorization
  regression test next to the guard it covers (see `groups_test.exs`, `posts_test.exs`). Run a
  single test with `mix test path:line`.
- Frontend has no unit runner — `npm run check` (svelte-check, must be **0 errors**) and
  `node scripts/check-i18n.mjs` are the only gates. Reuse existing components/APIs rather than
  adding new ones, and confirm both gates pass before opening a PR.

## Conventions

- ActivityPub is transport only — never let AP shape the internal model.
- Backend is authoritative for permissions; soft-delete everywhere (`deleted_at`); UUID actor
  IDs for federation stability; `created_at`/`updated_at` on all tables.
- All tunables are admin/DB-backed — do not hardcode limits.
- Elixir (from `backend/AGENTS.md`): use **`Req`** for HTTP (never httpoison/tesla/httpc);
  never `String.to_atom/1` on user input; predicate functions end in `?` (not `is_`); fields
  set programmatically (e.g. `user_id`) are set explicitly, never via `cast`; generate
  migrations with `mix ecto.gen.migration`. Tests use `start_supervised!/1` and monitors, not
  `Process.sleep/1`.
- Commits: **Conventional Commits in English** with scopes, e.g. `feat(web): …`,
  `fix(federation): …`, referencing the issue/PR number when relevant.

## Ongoing responsive/mobile work

`docs/MOBILE_AUDIT.md` tracks a cross-device (phone/tablet/desktop) audit: verified issues
with `file:line`, fixes, and a PR-batching plan. Guiding rules for that workstream: **improve
functionality, do not change the project's visual identity/design**; make features responsive
across all devices (target input type via `@media (pointer: coarse)`, not screen width alone);
prefer invisible fixes (e.g. extending a tap target with a transparent overlay) over restyling.
