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

// Access tokens are now 7 days (see Hybridsocial.Auth.Token). Refresh
// halfway through their lifetime when the tab is visible; the tab
// visibility listener below also triggers a refresh whenever the user
// returns to the page after the token might have gone stale.
const ACCESS_TOKEN_TTL_SECONDS = 7 * 24 * 3600;
const REFRESH_LEAD_SECONDS = ACCESS_TOKEN_TTL_SECONDS / 2;

let refreshTimer: ReturnType<typeof setTimeout> | null = null;
let visibilityListenerAttached = false;

function scheduleRefresh(expiresIn: number): void {
  if (refreshTimer) clearTimeout(refreshTimer);
  // Refresh well before expiry. Browsers cap setTimeout at ~24.8 days,
  // and long-suspended tabs don't reliably fire the timer anyway — the
  // visibilitychange hook picks up the slack when the tab wakes.
  const delayMs = Math.max((expiresIn - REFRESH_LEAD_SECONDS) * 1000, 30_000);
  refreshTimer = setTimeout(() => attemptRefresh(), Math.min(delayMs, 2_147_483_000));
}

async function attemptRefresh(retries = 2): Promise<void> {
  const state = get(authStore);
  if (!state.user) return;

  try {
    const { refreshTokens } = await import('$lib/api/auth.js');
    await refreshTokens();
    // Cookies rotate on success — reschedule based on the new TTL.
    scheduleRefresh(ACCESS_TOKEN_TTL_SECONDS);
  } catch (err: unknown) {
    const { ApiError } = await import('$lib/api/client.js');
    const isAuthError = err instanceof ApiError && (err.status === 401 || err.status === 403);

    if (isAuthError) {
      clearAuth();
    } else if (retries > 0) {
      setTimeout(() => attemptRefresh(retries - 1), 5_000);
    } else {
      // Network issue — don't log out, try again later
      scheduleRefresh(60);
    }
  }
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

  // Try to authenticate with httpOnly cookies. getCurrentUser will
  // trigger the api client's automatic refresh-on-401 path if the
  // access cookie expired while the tab was closed — so by the time
  // this returns, the session is either valid-and-refreshed or
  // definitively gone.
  authStore.update((s) => ({ ...s, loading: true }));
  try {
    const user = await getCurrentUser();
    authStore.update((s) => ({
      ...s,
      user,
      loading: false,
      initialized: true
    }));
    scheduleRefresh(ACCESS_TOKEN_TTL_SECONDS);
    attachVisibilityListener();

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
    const { ApiError } = await import('$lib/api/client.js');
    const isAuthError = err instanceof ApiError && (err.status === 401 || err.status === 403);

    if (isAuthError) {
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
api.setOnTokenRefreshed(() => {
  scheduleRefresh(ACCESS_TOKEN_TTL_SECONDS);
});

api.setOnAuthFailure(() => {
  sessionExpired.set(true);
  // Delay clearAuth so the banner shows briefly
  setTimeout(() => clearAuth(), 3000);
});
