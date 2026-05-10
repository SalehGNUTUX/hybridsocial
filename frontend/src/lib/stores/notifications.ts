import { writable, derived } from 'svelte/store';
import type { Notification } from '$lib/api/types.js';
import { browser } from '$app/environment';
import { serverReachable } from '$lib/stores/auth.js';

interface NotificationState {
  items: Notification[];
  unreadCount: number;
  loading: boolean;
}

export const notificationStore = writable<NotificationState>({
  items: [],
  unreadCount: 0,
  loading: false
});

export const unreadCount = derived(notificationStore, ($s) => $s.unreadCount);
export const notifications = derived(notificationStore, ($s) => $s.items);

let eventSource: EventSource | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectAttempts = 0;
let onlineListener: (() => void) | null = null;

// EventSource fires `onerror` for any transient blip — tab going to
// background, browser cell-network handoff, server graceful restart,
// SPA navigation. None of those are "the server is down". The banner
// should reflect the *API* being unreachable, not the SSE stream
// being flaky, so on every SSE error we wait out a grace window and
// then run a real HTTP probe before deciding to flip the user
// offline.
const OFFLINE_GRACE_MS = 15000;
let offlineGraceTimer: ReturnType<typeof setTimeout> | null = null;
let probeAbort: AbortController | null = null;
let visibilityListener: (() => void) | null = null;
let offlineEventListener: (() => void) | null = null;

function markReachable(): void {
  if (offlineGraceTimer) {
    clearTimeout(offlineGraceTimer);
    offlineGraceTimer = null;
  }
  if (probeAbort) {
    probeAbort.abort();
    probeAbort = null;
  }
  serverReachable.set(true);
}

// Lightweight reachability probe — hits the public instance endpoint
// (no auth, no body). Bounded by a 4s timeout so a hung TCP doesn't
// hold the user in "unknown" forever. Returns true only when the
// server answers HTTP-OK.
async function probeServer(): Promise<boolean> {
  if (probeAbort) probeAbort.abort();
  const ctrl = new AbortController();
  probeAbort = ctrl;
  const timeoutId = setTimeout(() => ctrl.abort(), 4000);
  try {
    const res = await fetch('/api/v1/instance', {
      method: 'GET',
      signal: ctrl.signal,
      cache: 'no-store',
      credentials: 'omit',
    });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timeoutId);
    if (probeAbort === ctrl) probeAbort = null;
  }
}

function scheduleOfflineFlip(): void {
  if (offlineGraceTimer) return;

  // OS already says we're offline → no point probing; flip immediately.
  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    serverReachable.set(false);
    return;
  }

  // Tab in background → defer until visible. The browser commonly kills
  // long-lived SSE on hidden tabs as a power-saving move; showing
  // "Connection lost" on a tab the user can't see is pure noise that
  // appears as a flash the moment they switch back. The
  // visibilitychange listener below re-evaluates when they return.
  if (typeof document !== 'undefined' && document.visibilityState === 'hidden') {
    return;
  }

  offlineGraceTimer = setTimeout(async () => {
    offlineGraceTimer = null;
    // If we reconnected during the wait, `markReachable()` already
    // cleared the state; bail without flipping.
    if (eventSource && eventSource.readyState === EventSource.OPEN) {
      serverReachable.set(true);
      return;
    }
    // SSE still down — probe the API itself. If the API responds, the
    // user is fine and we don't need to alarm them; the SSE reconnect
    // loop will eventually re-establish the live channel on its own.
    const ok = await probeServer();
    serverReachable.set(!ok ? false : true);
  }, OFFLINE_GRACE_MS);
}

export function setNotifications(items: Notification[]): void {
  const unread = items.filter((n) => !n.read).length;
  notificationStore.set({ items, unreadCount: unread, loading: false });
}

// Used by app boot to hydrate the bell badge before the user opens
// the notifications page. Setting just the counter avoids stomping on
// items that the page later loads.
export function setUnreadCount(count: number): void {
  notificationStore.update((s) => ({ ...s, unreadCount: count }));
}

// Pulls the unread count off the API on app boot so the navbar bell
// shows the right badge before the user opens /notifications. Silent
// failures — a stale 0 here is harmless and the SSE stream will
// fix-up the next time something fires.
export async function hydrateUnreadCount(): Promise<void> {
  try {
    const { getUnreadNotificationCount } = await import('$lib/api/notifications.js');
    const { count } = await getUnreadNotificationCount();
    setUnreadCount(count);
  } catch {
    // ignore — badge stays at its current value
  }
}

export function addNotification(notification: Notification): void {
  notificationStore.update((s) => ({
    items: [notification, ...s.items],
    unreadCount: notification.read ? s.unreadCount : s.unreadCount + 1,
    loading: s.loading
  }));
}

export function markRead(id: string): void {
  notificationStore.update((s) => ({
    items: s.items.map((n) => (n.id === id ? { ...n, read: true } : n)),
    unreadCount: Math.max(0, s.unreadCount - 1),
    loading: s.loading
  }));
}

/**
 * Flip every visible notification to read + zero the unread counter
 * without dropping the items from the list. Used by the /notifications
 * page on mount so the bell badge clears as soon as the user arrives,
 * while the list itself still shows the unread-highlight styling for
 * items the user hasn't clicked individually.
 */
export function markAllLocal(): void {
  notificationStore.update((s) => ({
    items: s.items.map((n) => ({ ...n, read: true })),
    unreadCount: 0,
    loading: s.loading,
  }));
}

export function clearAll(): void {
  notificationStore.set({ items: [], unreadCount: 0, loading: false });
}

export function connectNotificationStream(apiBase: string): void {
  if (!browser) return;
  stopReconnectTimer();
  closeEventSource();

  // Listen once for the browser's "back online" event — as soon as
  // the OS reports connectivity we retry immediately instead of
  // waiting out the backoff timer.
  if (!onlineListener) {
    onlineListener = () => {
      reconnectAttempts = 0;
      stopReconnectTimer();
      connectNotificationStream(apiBase);
    };
    window.addEventListener('online', onlineListener);
  }

  // OS-level offline → flip the banner immediately. The grace window
  // exists to hide SSE-only blips while the API is healthy; once the
  // OS says we have no network, there's nothing to be gained by
  // waiting 15 more seconds.
  if (!offlineEventListener) {
    offlineEventListener = () => {
      if (offlineGraceTimer) {
        clearTimeout(offlineGraceTimer);
        offlineGraceTimer = null;
      }
      serverReachable.set(false);
    };
    window.addEventListener('offline', offlineEventListener);
  }

  // When the tab regains visibility, re-evaluate. The browser may
  // have paused/killed the SSE while hidden; if we're still
  // disconnected, we want the *probe-backed* flip to run now, not
  // potentially much later.
  if (!visibilityListener) {
    visibilityListener = () => {
      if (document.visibilityState !== 'visible') return;
      const live = eventSource && eventSource.readyState === EventSource.OPEN;
      if (!live) {
        // Force a fresh reconnect attempt + re-arm the grace timer.
        stopReconnectTimer();
        reconnectAttempts = 0;
        connectNotificationStream(apiBase);
        scheduleOfflineFlip();
      }
    };
    document.addEventListener('visibilitychange', visibilityListener);
  }

  // SSE streaming — auth via httpOnly cookie (withCredentials sends cookies cross-origin)
  try {
    const url = `${apiBase}/api/v1/streaming/user`;
    eventSource = new EventSource(url, { withCredentials: true });

    eventSource.addEventListener('notification', (event) => {
      try {
        const notification: Notification = JSON.parse(event.data);
        addNotification(notification);
        // Fire the bell sound. The sound module self-gates on user
        // preference + audio unlock state, so nothing plays until the
        // user has interacted with the page and opted in.
        import('./sound.js').then((m) => m.playNotificationSound());
      } catch {
        // Ignore malformed events
      }
    });

    eventSource.onopen = () => {
      reconnectAttempts = 0;
      markReachable();
    };

    eventSource.onerror = () => {
      // Don't flip the banner on the first error — schedule a delayed
      // flip and let `onopen` of the reconnect cancel it. Only true
      // outages survive the grace window.
      scheduleOfflineFlip();
      closeEventSource();
      scheduleReconnect(apiBase);
    };
  } catch {
    // EventSource creation failed — silently ignore
  }
}

function scheduleReconnect(apiBase: string): void {
  stopReconnectTimer();
  // Exponential backoff: 1s, 2s, 4s, 8s, 16s, capped at 30s. Starts
  // aggressive so brief hiccups recover in ~1s instead of 10.
  const delay = Math.min(30_000, 1000 * 2 ** reconnectAttempts);
  reconnectAttempts += 1;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNotificationStream(apiBase);
  }, delay);
}

function stopReconnectTimer(): void {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

function closeEventSource(): void {
  if (eventSource) {
    eventSource.close();
    eventSource = null;
  }
}

export function disconnectNotificationStream(): void {
  stopReconnectTimer();
  closeEventSource();
  if (offlineGraceTimer) {
    clearTimeout(offlineGraceTimer);
    offlineGraceTimer = null;
  }
  if (probeAbort) {
    probeAbort.abort();
    probeAbort = null;
  }
  if (onlineListener) {
    window.removeEventListener('online', onlineListener);
    onlineListener = null;
  }
  if (offlineEventListener) {
    window.removeEventListener('offline', offlineEventListener);
    offlineEventListener = null;
  }
  if (visibilityListener) {
    document.removeEventListener('visibilitychange', visibilityListener);
    visibilityListener = null;
  }
  reconnectAttempts = 0;
}
