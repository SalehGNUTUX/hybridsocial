import { writable } from 'svelte/store';
import { browser } from '$app/environment';

// A lightweight, frontend-only record of accounts this browser has signed in
// as, powering the account switcher in the header menu. It deliberately stores
// NO tokens — sessions live in httpOnly cookies, so switching still routes
// through the login page (pre-filled). This just remembers who you are, so the
// menu can offer "switch to @other" / "add another account".
export interface KnownAccount {
  id: string;
  handle: string;
  display_name: string;
  avatar_url: string | null;
}

const KEY = 'hs-known-accounts';
const MAX = 8;

function load(): KnownAccount[] {
  if (!browser) return [];
  try {
    const raw = localStorage.getItem(KEY);
    const arr = raw ? JSON.parse(raw) : [];
    return Array.isArray(arr) ? arr.filter((a) => a && typeof a.handle === 'string') : [];
  } catch {
    return [];
  }
}

export const knownAccounts = writable<KnownAccount[]>(load());

function persist(list: KnownAccount[]): void {
  if (!browser) return;
  try {
    localStorage.setItem(KEY, JSON.stringify(list));
  } catch {
    // storage unavailable (private mode) — the switcher just won't persist
  }
}

// Upsert an account after a successful auth. Moves it to the front (most
// recent), refreshes its display fields, and caps the list.
export function rememberAccount(a: {
  id?: string;
  handle?: string;
  display_name?: string | null;
  avatar_url?: string | null;
}): void {
  if (!a?.handle) return;
  knownAccounts.update((list) => {
    const entry: KnownAccount = {
      id: a.id ?? '',
      handle: a.handle as string,
      display_name: a.display_name || (a.handle as string),
      avatar_url: a.avatar_url ?? null,
    };
    const rest = list.filter((x) => x.handle !== entry.handle);
    const next = [entry, ...rest].slice(0, MAX);
    persist(next);
    return next;
  });
}

// Drop an account from the switcher (does not touch any session).
export function forgetAccount(handle: string): void {
  knownAccounts.update((list) => {
    const next = list.filter((x) => x.handle !== handle);
    persist(next);
    return next;
  });
}
