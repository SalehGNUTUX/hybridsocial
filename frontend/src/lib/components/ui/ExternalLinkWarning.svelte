<script lang="ts">
  import { onMount } from 'svelte';
  import {
    isDomainTrusted,
    trustDomain,
    isWarningDisabled,
  } from '$lib/utils/external-link-trust.js';
  import SafeUrl from './SafeUrl.svelte';
  import { instanceName } from '$lib/stores/instance.js';

  let pendingUrl = $state<string | null>(null);
  let pendingDomain = $state<string>('');
  let trustNextTime = $state(false);
  let cancelButton: HTMLButtonElement | null = $state(null);
  let lastFocused: HTMLElement | null = null;

  // Determine whether a click should trigger the warning.
  function shouldIntercept(event: MouseEvent): { url: string; domain: string } | null {
    // Respect modifier-clicks — user explicitly wants to bypass (open
    // in new tab manually, save link, etc).
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return null;
    // Right/middle clicks aren't real navigations.
    if (event.button !== 0) return null;

    const target = event.target as Element | null;
    if (!target || !target.closest) return null;

    const anchor = target.closest('a[href]') as HTMLAnchorElement | null;
    if (!anchor) return null;

    // Explicit escape hatch: any anchor with data-no-warn is exempt
    // (use it for in-app links that look external for technical
    // reasons, like federated user profiles served via redirect).
    if (anchor.hasAttribute('data-no-warn')) return null;

    const href = anchor.getAttribute('href');
    if (!href) return null;

    // Skip non-http(s) schemes — mailto/tel/sms have their own UI and
    // javascript: URIs should be blocked by the HTML sanitizer
    // upstream anyway.
    const lower = href.toLowerCase();
    if (
      lower.startsWith('mailto:') ||
      lower.startsWith('tel:') ||
      lower.startsWith('sms:') ||
      lower.startsWith('javascript:') ||
      lower.startsWith('#') ||
      lower.startsWith('blob:') ||
      lower.startsWith('data:')
    ) {
      return null;
    }

    // Resolve relative URLs against the current document.
    let url: URL;
    try {
      url = new URL(href, window.location.href);
    } catch {
      return null;
    }

    // Same origin — internal navigation, don't warn.
    if (url.origin === window.location.origin) return null;

    return { url: url.href, domain: url.hostname };
  }

  function handleGlobalClick(event: MouseEvent) {
    if (isWarningDisabled()) return;

    const hit = shouldIntercept(event);
    if (!hit) return;

    if (isDomainTrusted(hit.domain)) return;

    // Block the navigation and show the modal.
    event.preventDefault();
    event.stopPropagation();

    lastFocused = document.activeElement as HTMLElement | null;
    pendingUrl = hit.url;
    pendingDomain = hit.domain;
    trustNextTime = false;
  }

  function close() {
    pendingUrl = null;
    pendingDomain = '';
    trustNextTime = false;
    if (lastFocused && typeof lastFocused.focus === 'function') {
      lastFocused.focus();
      lastFocused = null;
    }
  }

  function handleContinue() {
    if (!pendingUrl) return;
    if (trustNextTime && pendingDomain) {
      trustDomain(pendingDomain);
    }
    // Open in a new tab with hardened relationship attrs so the
    // destination can't reach back via window.opener.
    window.open(pendingUrl, '_blank', 'noopener,noreferrer');
    close();
  }

  function handleKeydown(e: KeyboardEvent) {
    if (!pendingUrl) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      close();
    }
  }

  // Capture-phase listener so we run before site-specific handlers
  // navigate via JS (e.g. components that call goto() from onclick).
  onMount(() => {
    document.addEventListener('click', handleGlobalClick, true);
    return () => document.removeEventListener('click', handleGlobalClick, true);
  });

  // Move focus into the dialog when it opens.
  $effect(() => {
    if (pendingUrl && cancelButton) {
      cancelButton.focus();
    }
  });
</script>

<svelte:window onkeydown={handleKeydown} />

{#if pendingUrl}
  <div
    class="elw-backdrop"
    role="dialog"
    aria-modal="true"
    aria-labelledby="elw-title"
    aria-describedby="elw-url"
    onclick={(e) => {
      if (e.target === e.currentTarget) close();
    }}
    onkeydown={(e) => {
      if (e.key === 'Escape') close();
    }}
    tabindex="-1"
  >
    <div class="elw-modal" role="document">
      <h2 id="elw-title" class="elw-title">Leaving {$instanceName}</h2>
      <p class="elw-sub">
        You're about to open a link on another site. Check the URL
        below carefully — phishing pages often use lookalike domains.
      </p>

      <div id="elw-url" class="elw-url">
        <SafeUrl url={pendingUrl} />
      </div>

      <label class="elw-trust">
        <input type="checkbox" bind:checked={trustNextTime} />
        <span>Don't warn me again for <strong>{pendingDomain}</strong> today</span>
      </label>

      <div class="elw-actions">
        <button
          type="button"
          class="elw-btn elw-btn-ghost"
          onclick={close}
          bind:this={cancelButton}
        >
          Cancel
        </button>
        <button type="button" class="elw-btn elw-btn-primary" onclick={handleContinue}>
          Continue
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .elw-backdrop {
    position: fixed;
    inset: 0;
    /* Blur the background so the foreground modal is obviously the
       thing in focus — matches the connection/session-expired dialog
       we ship elsewhere. Fall back to a plain dim on old browsers
       that don't support backdrop-filter. */
    background: var(--scrim-medium);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 9999;
    padding: var(--space-4);
  }

  .elw-modal {
    background: var(--color-surface, white);
    color: var(--color-text);
    border-radius: var(--radius-lg, 12px);
    box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
    max-width: 480px;
    width: 100%;
    padding: var(--space-5, 20px);
    display: flex;
    flex-direction: column;
    gap: var(--space-3, 12px);
  }

  .elw-title {
    font-size: var(--text-lg, 1.125rem);
    font-weight: 700;
    margin: 0;
  }

  .elw-sub {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm, 0.875rem);
    line-height: 1.5;
    margin: 0;
  }

  .elw-url {
    background: var(--color-surface-alt, rgba(0, 0, 0, 0.04));
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 8px);
    padding: var(--space-3, 12px);
    display: flex;
    flex-direction: column;
    gap: 4px;
    overflow: hidden;
  }

  .elw-trust {
    display: flex;
    align-items: flex-start;
    gap: var(--space-2, 8px);
    font-size: var(--text-sm, 0.875rem);
    color: var(--color-text);
    cursor: pointer;
  }

  .elw-trust input {
    margin-block-start: 3px;
  }

  .elw-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2, 8px);
    margin-block-start: var(--space-2, 8px);
  }

  .elw-btn {
    padding: 10px 18px;
    border-radius: 9999px;
    font-size: var(--text-sm, 0.875rem);
    font-weight: 600;
    border: none;
    cursor: pointer;
    transition: background-color 0.15s ease, transform 0.1s ease;
  }

  .elw-btn-ghost {
    background: transparent;
    color: var(--color-text-secondary);
  }

  .elw-btn-ghost:hover {
    background: var(--scrim-soft);
    color: var(--color-text);
  }

  .elw-btn-primary {
    background: var(--color-primary, #3b82f6);
    color: white;
  }

  .elw-btn-primary:hover {
    background: var(--color-primary-hover, #2563eb);
  }

  .elw-btn:active:not(:disabled) {
    transform: scale(0.98);
  }
</style>
