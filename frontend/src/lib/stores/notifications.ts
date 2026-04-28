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

// EventSource fires `onerror` for any transient blip — including the
// half-second pauses some browsers impose on long-lived connections
// during SPA navigation. Without a grace window, the "Connection
// lost" overlay flashes on every page change. Delay the offline flip
// long enough that real outages still surface, but routine reconnect
// noise is invisible.
const OFFLINE_GRACE_MS = 8000;
let offlineGraceTimer: ReturnType<typeof setTimeout> | null = null;

function markReachable(): void {
  if (offlineGraceTimer) {
    clearTimeout(offlineGraceTimer);
    offlineGraceTimer = null;
  }
  serverReachable.set(true);
}

function scheduleOfflineFlip(): void {
  if (offlineGraceTimer) return;
  offlineGraceTimer = setTimeout(() => {
    offlineGraceTimer = null;
    serverReachable.set(false);
  }, OFFLINE_GRACE_MS);
}

export function setNotifications(items: Notification[]): void {
  const unread = items.filter((n) => !n.read).length;
  notificationStore.set({ items, unreadCount: unread, loading: false });
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
  if (onlineListener) {
    window.removeEventListener('online', onlineListener);
    onlineListener = null;
  }
  reconnectAttempts = 0;
}
