import { get } from 'svelte/store';
import { goto } from '$app/navigation';
import { focusedPostId, focusNextPost, focusPrevPost } from '$lib/stores/focused-post.js';
import { currentUser } from '$lib/stores/auth.js';

// Mastodon-style global keyboard shortcuts. Designed to mirror the
// muscle memory most fediverse users already have. The chord prefix
// `g` opens a 1500ms window for a "go to" target; any other prefix
// or unmapped second key cancels silently.

export type ShortcutEntry = {
  keys: string;
  description: string;
  group: 'navigation' | 'compose' | 'feed' | 'post' | 'help';
};

export const SHORTCUTS: ShortcutEntry[] = [
  { keys: 'g h', description: 'Go to Home', group: 'navigation' },
  { keys: 'g n', description: 'Go to Notifications', group: 'navigation' },
  { keys: 'g e', description: 'Go to Explore', group: 'navigation' },
  { keys: 'g m', description: 'Go to Messages', group: 'navigation' },
  { keys: 'g b', description: 'Go to Bookmarks', group: 'navigation' },
  { keys: 'g s', description: 'Go to Settings', group: 'navigation' },
  { keys: 'g u', description: 'Go to your profile', group: 'navigation' },
  { keys: 'g d', description: 'Go to Drafts', group: 'navigation' },
  { keys: 'g t', description: 'Scroll to top', group: 'navigation' },
  { keys: 'n', description: 'New post', group: 'compose' },
  { keys: 'Esc', description: 'Close composer or modal', group: 'compose' },
  { keys: 'j', description: 'Next post', group: 'feed' },
  { keys: 'k', description: 'Previous post', group: 'feed' },
  { keys: 'o / Enter', description: 'Open focused post', group: 'feed' },
  { keys: 'Backspace', description: 'Go back', group: 'feed' },
  { keys: 'r', description: 'Reply to focused post', group: 'post' },
  { keys: 'b', description: 'Boost focused post', group: 'post' },
  { keys: 'f', description: 'React (like) to focused post', group: 'post' },
  { keys: 'x', description: 'Toggle CW / sensitive reveal', group: 'post' },
  { keys: '?', description: 'Show this help', group: 'help' },
];

const NAV_TARGETS: Record<string, string | (() => string | null)> = {
  h: '/home',
  n: '/notifications',
  e: '/explore',
  m: '/messages',
  b: '/bookmarks',
  s: '/settings',
  d: '/drafts',
  u: () => {
    const u = get(currentUser);
    return u ? `/@${u.handle}` : null;
  },
};

let installed = false;
let prefix: 'g' | null = null;
let prefixTimer: ReturnType<typeof setTimeout> | null = null;

function clearPrefix(): void {
  prefix = null;
  if (prefixTimer) {
    clearTimeout(prefixTimer);
    prefixTimer = null;
  }
}

function setPrefix(p: 'g'): void {
  prefix = p;
  if (prefixTimer) clearTimeout(prefixTimer);
  prefixTimer = setTimeout(clearPrefix, 1500);
}

function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  if (target.matches('input, textarea, select, [contenteditable=""], [contenteditable="true"]')) {
    return true;
  }
  if (target.closest('[data-no-shortcuts]')) return true;
  // The composer panel sets `data-composer-open` while it's mounted —
  // even when focus isn't directly on the textarea (e.g., the visibility
  // dropdown is open) we don't want `n` to swallow keystrokes meant
  // for the visible UI underneath.
  if (document.body.dataset.composerOpen === 'true') {
    // Only Esc and `?` should pass through while composing.
    return true;
  }
  return false;
}

function dispatchPostAction(action: 'reply' | 'boost' | 'react' | 'toggle-cw'): void {
  const id = get(focusedPostId);
  if (!id) return;
  window.dispatchEvent(
    new CustomEvent('post-shortcut-action', { detail: { id, action } }),
  );
}

function openShortcutsHelp(): void {
  window.dispatchEvent(new CustomEvent('open-shortcuts-help'));
}

function openComposer(): void {
  window.dispatchEvent(new CustomEvent('open-composer'));
}

function openFocusedPost(): void {
  const id = get(focusedPostId);
  if (!id) return;
  goto(`/post/${id}`);
}

function scrollToTop(): void {
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function handleKeydown(e: KeyboardEvent): void {
  // Ignore modifier-augmented keys so OS shortcuts (Cmd+R, Ctrl+F, etc.)
  // pass through unchanged.
  if (e.metaKey || e.ctrlKey || e.altKey) return;

  const isTyping = isTypingTarget(e.target);

  // Esc and ? are allowed even while typing (Esc closes composer; ?
  // is harmless since shift+? still requires Shift modifier and most
  // text fields produce literal `?` instead). Actually `?` while
  // typing should NOT trigger help — only when not typing.
  if (e.key === 'Escape') {
    // Composer + modals already wire their own Escape handlers; let
    // the event continue to bubble. We just clear any pending chord.
    clearPrefix();
    return;
  }

  if (isTyping) return;

  // Help — `?` requires Shift on most layouts, but the resulting
  // `event.key` is the literal `?` so we match on that.
  if (e.key === '?') {
    e.preventDefault();
    openShortcutsHelp();
    return;
  }

  // Chord follow-up: a navigation target after `g`.
  if (prefix === 'g') {
    const k = e.key.toLowerCase();
    const target = NAV_TARGETS[k];
    clearPrefix();
    if (target === undefined && k !== 't') return;
    e.preventDefault();
    if (k === 't') {
      scrollToTop();
      return;
    }
    const path = typeof target === 'function' ? target() : target;
    if (path) goto(path);
    return;
  }

  // Single-key shortcuts.
  switch (e.key) {
    case 'g':
      e.preventDefault();
      setPrefix('g');
      return;
    case 'n':
      e.preventDefault();
      openComposer();
      return;
    case 'j':
      e.preventDefault();
      focusNextPost();
      return;
    case 'k':
      e.preventDefault();
      focusPrevPost();
      return;
    case 'o':
    case 'Enter':
      if (e.key === 'Enter') {
        // Don't hijack Enter on buttons/links — only when focus is on
        // the body (no actionable element beneath).
        if (
          e.target instanceof HTMLElement &&
          e.target.closest('a, button, [role="button"]')
        ) {
          return;
        }
      }
      if (!get(focusedPostId)) return;
      e.preventDefault();
      openFocusedPost();
      return;
    case 'Backspace':
      if (e.target !== document.body && e.target !== document.documentElement) return;
      e.preventDefault();
      history.back();
      return;
    case 'r':
      e.preventDefault();
      dispatchPostAction('reply');
      return;
    case 'b':
      e.preventDefault();
      dispatchPostAction('boost');
      return;
    case 'f':
      e.preventDefault();
      dispatchPostAction('react');
      return;
    case 'x':
      e.preventDefault();
      dispatchPostAction('toggle-cw');
      return;
  }
}

export function installShortcuts(): () => void {
  if (installed) return () => undefined;
  installed = true;
  window.addEventListener('keydown', handleKeydown);
  return () => {
    installed = false;
    window.removeEventListener('keydown', handleKeydown);
    clearPrefix();
  };
}
