import { writable, derived, get } from 'svelte/store';
import { api } from '$lib/api/client.js';
import { getCurrentUser } from '$lib/api/auth.js';
import type { Identity } from '$lib/api/types.js';
import { browser } from '$app/environment';

interface AuthState {
  user: Identity | null;
  loading: boolean;
  initialized: boolean;
}

const initialState: AuthState = {
  user: null,
  loading: false,
  initialized: false
};

export const authStore = writable<AuthState>(initialState);
export const currentUser = derived(authStore, ($s) => $s.user);
export const isLoggedIn = derived(authStore, ($s) => !!$s.user);
export const isAuthLoading = derived(authStore, ($s) => $s.loading);
export const isAdmin = derived(authStore, ($s) => $s.user?.is_admin === true);
export const isStaffMember = derived(authStore, ($s) => ($s.user?.roles?.length ?? 0) > 0 || $s.user?.is_admin === true);

// Signals to the ConnectionBanner
export const sessionExpired = writable(false);
export const serverReachable = writable(true);

export function hasPermission(permission: string): boolean {
  const state = get(authStore);
  return state.user?.permissions?.includes(permission) ?? false;
}

export function hasAnyPermission(...permissions: string[]): boolean {
  const state = get(authStore);
  if (!state.user?.permissions) return false;
  return permissions.some((p) => state.user!.permissions.includes(p));
}

export function isStaff(): boolean {
  const state = get(authStore);
  return (state.user?.roles?.length ?? 0) > 0;
}

// ---- Token Refresh ----

// Access tokens are 15 minutes (see Hybridsocial.Auth.Token — shortened
// from 7 days by the token-revocation hardening). We refresh ~1 minute
// before expiry so a foregrounded tab's token never lapses, which keeps
// each device's session alive independently. The visibilitychange hook
// below covers tabs that were suspended past expiry (the setTimeout
// won't have fired reliably while backgrounded). This is a fallback TTL
// only — the actual refresh reschedules off the server's `expires_in`.
const DEFAULT_ACCESS_TTL_SECONDS = 15 * 60;
const REFRESH_LEAD_SECONDS = 60;

let refreshTimer: ReturnType<typeof setTimeout> | null = null;
let visibilityListenerAttached = false;

function scheduleRefresh(expiresIn: number): void {
  if (refreshTimer) clearTimeout(refreshTimer);
  // Refresh REFRESH_LEAD_SECONDS before expiry, but never busier than
  // every 30s. Browsers cap setTimeout at ~24.8 days; long-suspended
  // tabs don't fire the timer reliably anyway — the visibilitychange
  // hook picks up the slack when the tab wakes.
  const delayMs = Math.max((expiresIn - REFRESH_LEAD_SECONDS) * 1000, 30_000);
  refreshTimer = setTimeout(() => attemptRefresh(), Math.min(delayMs, 2_147_483_000));
}

async function attemptRefresh(): Promise<void> {
  const state = get(authStore);
  if (!state.user) return;

  // Route through the api client's single-flight lock so a proactive or
  // visibility-triggered refresh can't race the reactive 401 refresh and
  // double-rotate the refresh token (the loser 401s and bounces to
  // /login).
  const result = await api.refresh();

  // 'ok' → onTokenRefreshed already rescheduled off the real TTL.
  // 'auth_failed' → the refresh token itself is dead (expired past 90d or
  //   revoked); this is a genuine sign-out.
  // 'deferred' → transient network/server issue; keep the session and
  //   retry shortly rather than logging the user out.
  if (result === 'auth_failed') {
    handleSessionExpired();
  } else if (result === 'deferred') {
    scheduleRefresh(REFRESH_LEAD_SECONDS + 60);
  }
}

// Surface the "session expired" banner briefly, then clear auth. Shared
// by the proactive refresh and the api client's reactive 401 path so a
// dead session is handled the same way everywhere.
function handleSessionExpired(): void {
  sessionExpired.set(true);
  setTimeout(() => clearAuth(), 3000);
}

// Refresh when the tab comes back into focus after being hidden.
// Covers the common "laptop closed overnight" case where the setTimeout
// fires late (or not at all) and the next API call would otherwise race
// the refresh, sometimes bouncing the user to /login unnecessarily.
function attachVisibilityListener(): void {
  if (visibilityListenerAttached || !browser) return;
  visibilityListenerAttached = true;

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return;
    const state = get(authStore);
    if (state.user) attemptRefresh();
  });
}

// ---- Public API ----

export function setUser(user: Identity): void {
  authStore.update((s) => ({ ...s, user }));
  // Remember freshly-authenticated accounts too (login calls setUser directly,
  // not initAuth). Upsert is idempotent; fire-and-forget.
  import('$lib/stores/known-accounts.js')
    .then((m) => m.rememberAccount(user))
    .catch(() => {});
}

export function clearAuth(): void {
  if (refreshTimer) clearTimeout(refreshTimer);

  try {
    import('$lib/stores/notifications.js').then(({ disconnectNotificationStream }) => {
      disconnectNotificationStream();
    });
  } catch {}

  authStore.set({
    user: null,
    loading: false,
    initialized: true
  });
}

export async function initAuth(): Promise<void> {
  const state = get(authStore);
  if (state.initialized) return;

  if (!browser) {
    authStore.update((s) => ({ ...s, initialized: true }));
    return;
  }

  authStore.update((s) => ({ ...s, loading: true }));

  const { ApiError } = await import('$lib/api/client.js');
  const isAuthError = (e: unknown) =>
    e instanceof ApiError && (e.status === 401 || e.status === 403);

  try {
    // Bootstrap the session from the httpOnly cookies. If the short-lived
    // access token expired while we were away, /auth/me returns 401 — but
    // /auth/me is excluded from the client's automatic refresh, so we do
    // one explicit refresh here using the long-lived (90-day) refresh
    // cookie and retry. A returning user should never have to log in again
    // while that refresh token is still alive — this is what makes staying
    // signed in across inactivity behave like any normal site. If the
    // refresh cookie is missing/expired the user is genuinely logged out,
    // and we stay silent (no "session expired" banner for anon visitors).
    let user: Identity;
    try {
      user = await getCurrentUser();
    } catch (err) {
      if (!isAuthError(err)) throw err;

      const result = await api.refresh();
      if (result !== 'ok') {
        authStore.update((s) => ({ ...s, user: null, loading: false, initialized: true }));
        return;
      }
      user = await getCurrentUser();
    }

    authStore.update((s) => ({
      ...s,
      user,
      loading: false,
      initialized: true
    }));
    scheduleRefresh(DEFAULT_ACCESS_TTL_SECONDS);
    attachVisibilityListener();

    // Remember this account for the header's quick-switch menu. Frontend-only
    // list, no tokens stored — switching still re-authenticates via /login.
    try {
      const { rememberAccount } = await import('$lib/stores/known-accounts.js');
      rememberAccount(user);
    } catch {
      /* switcher is non-critical */
    }

    // Sync server preferences to local stores
    if ((user as any).locale) {
      try {
        const { setLocale } = await import('$lib/utils/i18n.js');
        await setLocale((user as any).locale);
        const { locale } = await import('$lib/stores/i18n.js');
        locale.set((user as any).locale);
      } catch { /* i18n not critical */ }
    }
    // Sync all preferences from server
    try {
      const { applyServerPreferences } = await import('$lib/stores/preferences.js');
      applyServerPreferences(
        (user as any).preferences || {},
        (user as any).default_visibility
      );
    } catch { /* preferences not critical */ }
  } catch (err: unknown) {
    if (isAuthError(err)) {
      // No valid session — user is not logged in
      authStore.update((s) => ({ ...s, user: null, loading: false, initialized: true }));
    } else {
      // Network error — can't determine auth state, mark initialized but no user
      authStore.update((s) => ({ ...s, loading: false, initialized: true }));
      scheduleRefresh(30);
    }
  }
}

// Wire up API client callbacks
api.setOnTokenRefreshed((expiresIn?: number) => {
  scheduleRefresh(expiresIn ?? DEFAULT_ACCESS_TTL_SECONDS);
});

api.setOnAuthFailure(handleSessionExpired);
