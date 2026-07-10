<script lang="ts">
  import { onMount } from 'svelte';
  import { currentUser } from '$lib/stores/auth.js';
  import { addToast } from '$lib/stores/toast.js';

  // The backend's RequireAdmin plug enforces 2FA for *anyone* with at
  // least one active role — admin, moderator, or any custom staff
  // role. Same trigger here so a staff member finds out they need to
  // turn 2FA on before they hit a 403, instead of after.

  function shouldShow(
    user: { roles?: string[]; two_factor_enabled?: boolean; security_keys_enabled?: boolean } | null,
  ): boolean {
    if (!user) return false;
    const isStaff = (user.roles?.length ?? 0) > 0;
    // Either an authenticator app (TOTP) or a registered security key
    // satisfies the staff 2FA requirement, so don't nag a user who's
    // already covered by a passkey.
    const hasSecondFactor = user.two_factor_enabled === true || user.security_keys_enabled === true;
    return isStaff && !hasSecondFactor;
  }

  // Per-session dismiss: clicking X stops it for the rest of the tab,
  // but the next browser session will surface it again until 2FA is
  // actually on. We never permanently silence the banner — the whole
  // point is to keep it visible until the gate is satisfied.
  const DISMISS_KEY = 'staff-otp-banner-dismissed';
  let dismissed = $state(false);
  let toasted = false;

  let user = $derived($currentUser);
  let visible = $derived(!dismissed && shouldShow(user));

  onMount(() => {
    if (typeof sessionStorage !== 'undefined') {
      dismissed = sessionStorage.getItem(DISMISS_KEY) === '1';
    }
  });

  // Fire a toast the first time the banner becomes relevant in this
  // session — louder than the banner alone, but only once.
  $effect(() => {
    if (visible && !toasted) {
      toasted = true;
      addToast(
        'Your account has staff access. Enable 2FA at Settings → Security to use the admin panel.',
        'warning',
        8000,
      );
    }
  });

  function dismiss() {
    dismissed = true;
    if (typeof sessionStorage !== 'undefined') {
      sessionStorage.setItem(DISMISS_KEY, '1');
    }
  }
</script>

{#if visible}
  <div class="staff-otp-banner" role="alert">
    <span class="material-symbols-outlined banner-icon" aria-hidden="true">shield_lock</span>
    <p class="banner-text">
      <strong>2FA required for your role.</strong>
      Your account has staff access, but the admin panel is locked
      until two-factor auth is enabled.
    </p>
    <a class="banner-action" href="/settings/security">Enable 2FA</a>
    <button
      type="button"
      class="banner-dismiss"
      onclick={dismiss}
      aria-label="Dismiss until next session"
    >
      <span class="material-symbols-outlined" aria-hidden="true">close</span>
    </button>
  </div>
{/if}

<style>
  .staff-otp-banner {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 16px;
    background: var(--color-warning-soft);
    border-block-end: 1px solid rgba(234, 179, 8, 0.4);
    color: var(--color-on-warning-soft);
    font-size: 0.875rem;
  }

  .banner-icon {
    font-size: 22px;
    color: var(--color-on-warning-soft);
    flex-shrink: 0;
  }

  .banner-text {
    margin: 0;
    flex: 1;
    line-height: 1.4;
  }

  .banner-text strong {
    margin-inline-end: 4px;
  }

  .banner-action {
    flex-shrink: 0;
    padding: 6px 14px;
    border-radius: 9999px;
    background: var(--color-primary);
    color: var(--color-text-on-primary, #fff);
    font-weight: 600;
    text-decoration: none;
    font-size: 0.8125rem;
  }

  .banner-action:hover {
    text-decoration: none;
    filter: brightness(1.05);
  }

  .banner-dismiss {
    flex-shrink: 0;
    background: transparent;
    border: none;
    color: inherit;
    cursor: pointer;
    border-radius: 9999px;
    width: 28px;
    height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    opacity: 0.7;
  }

  .banner-dismiss:hover {
    opacity: 1;
    background: rgba(234, 179, 8, 0.2);
  }

  .banner-dismiss .material-symbols-outlined {
    font-size: 18px;
  }

  @media (max-width: 640px) {
    .staff-otp-banner {
      flex-wrap: wrap;
    }
    .banner-text {
      flex-basis: 100%;
      order: 2;
    }
  }
</style>
