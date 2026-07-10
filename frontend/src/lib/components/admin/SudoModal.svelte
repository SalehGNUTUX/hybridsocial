<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { browser } from '$app/environment';
  import { sudoExpiresAt } from '$lib/stores/admin-sudo.js';
  import SudoGate from './SudoGate.svelte';

  // Staff/mod affordances exist outside /admin (e.g. the moderation
  // panel on a user profile) and also hit sudo-gated endpoints. When
  // any of those 403s with auth.sudo_required, the API client emits
  // `admin-sudo-required` — this component listens app-wide and pops
  // an overlay that unlocks sudo without forcing a trip to /admin.

  let open = $state(false);

  function show() {
    open = true;
  }

  function close() {
    open = false;
  }

  function handleUnlocked(expiresAt: string) {
    sudoExpiresAt.set(expiresAt);
    open = false;
  }

  function handleOverlayClick(e: MouseEvent) {
    if (e.target === e.currentTarget) close();
  }

  function handleKeydown(e: KeyboardEvent) {
    if (open && e.key === 'Escape') close();
  }

  onMount(() => {
    window.addEventListener('admin-sudo-required', show);
    window.addEventListener('keydown', handleKeydown);
  });

  onDestroy(() => {
    if (!browser) return;
    window.removeEventListener('admin-sudo-required', show);
    window.removeEventListener('keydown', handleKeydown);
  });
</script>

{#if open}
  <div class="sudo-modal-backdrop" role="presentation" onclick={handleOverlayClick}>
    <div class="sudo-modal-surface" role="dialog" aria-modal="true" aria-label="Confirm your identity">
      <button
        type="button"
        class="sudo-modal-close"
        aria-label="Close"
        onclick={close}
      >
        ✕
      </button>
      <SudoGate onUnlocked={handleUnlocked} />
    </div>
  </div>
{/if}

<style>
  .sudo-modal-backdrop {
    position: fixed;
    inset: 0;
    background: var(--scrim-medium);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: var(--space-4);
    /* Above everything app-chrome — sudo is an interruptive action. */
    z-index: 10000;
    backdrop-filter: blur(3px);
  }

  .sudo-modal-surface {
    position: relative;
    max-width: 520px;
    width: 100%;
  }

  .sudo-modal-close {
    position: absolute;
    inset-block-start: 8px;
    inset-inline-end: 8px;
    width: 32px;
    height: 32px;
    border: 0;
    background: transparent;
    color: var(--color-text-secondary);
    font-size: 1rem;
    cursor: pointer;
    border-radius: var(--radius-full);
    z-index: 1;
  }

  .sudo-modal-close:hover {
    background: var(--color-surface);
    color: var(--color-text);
  }
</style>
