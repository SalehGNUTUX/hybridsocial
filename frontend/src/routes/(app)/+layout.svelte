<script lang="ts">
  import { goto } from '$app/navigation';
  import { browser } from '$app/environment';
  import AppLayout from '$lib/components/layout/AppLayout.svelte';
  import ConnectionBanner from '$lib/components/ui/ConnectionBanner.svelte';
  import OnboardingModal from '$lib/components/ui/OnboardingModal.svelte';
  import { authStore } from '$lib/stores/auth.js';
  import { connectNotificationStream, disconnectNotificationStream } from '$lib/stores/notifications.js';
  import { connectChatStream, disconnectChatStream } from '$lib/stores/chat-stream.js';
  import { initSound } from '$lib/stores/sound.js';
  import { initDmUnread } from '$lib/stores/dm-unread.js';
  import { cookieConsent, hasConsented } from '$lib/stores/consent.js';
  import CookieBanner from '$lib/components/ui/CookieBanner.svelte';
  import { subscribeToPush } from '$lib/utils/push.js';
  import { loadFilters } from '$lib/stores/content-filters.js';
  import PostComposer from '$lib/components/post/PostComposer.svelte';
  import SudoModal from '$lib/components/admin/SudoModal.svelte';
  import KeyboardShortcutsModal from '$lib/components/ui/KeyboardShortcutsModal.svelte';
  import { installShortcuts } from '$lib/utils/shortcuts.js';
  import { onDestroy } from 'svelte';
  import { page } from '$app/state';

  // Routes where the floating "new post" FAB makes no sense and just
  // gets in the way of real UI (DMs hide the message input behind it;
  // admin/settings are task-focused and the user isn't there to post).
  const NO_COMPOSER_PREFIXES = ['/messages', '/admin', '/settings'];
  let showComposer = $derived(
    !NO_COMPOSER_PREFIXES.some((p) => page.url.pathname.startsWith(p)),
  );

  let { children } = $props();
  let authState = $state({ user: null as any, initialized: false });
  let consented = $state(hasConsented());
  let showOnboarding = $state(false);
  let streamsStarted = false;
  let redirecting = $state(false);

  cookieConsent.subscribe((v) => (consented = v));
  const unsubAuth = authStore.subscribe((s) => (authState = s));

  // Gate rendering + side-effects on auth being resolved. Until the
  // root layout's initAuth() finishes we don't know whether the user
  // is logged in, so rendering the authed app shell (or connecting
  // SSE streams) just produces 401s and a misleading "Connection
  // lost" banner before the login redirect fires.
  $effect(() => {
    if (!browser || !authState.initialized) return;

    if (!authState.user) {
      if (!redirecting) {
        redirecting = true;
        goto('/login');
      }
      return;
    }

    if (!streamsStarted) {
      streamsStarted = true;
      const apiBase = import.meta.env.VITE_API_URL || '';
      connectNotificationStream(apiBase);
      connectChatStream(apiBase);
      initSound();
      initDmUnread();
      subscribeToPush();
      loadFilters();
      uninstallShortcuts = installShortcuts();

      if (!authState.user.onboarded_at) {
        showOnboarding = true;
      }
    }
  });

  let uninstallShortcuts: (() => void) | null = null;

  onDestroy(() => {
    disconnectNotificationStream();
    disconnectChatStream();
    unsubAuth();
    uninstallShortcuts?.();
  });
</script>

{#if !consented}
  <CookieBanner onaccept={() => consented = true} />
{:else if !authState.initialized || !authState.user}
  <!-- Hold the shell blank until auth is resolved. Rendering authed
       pages before we know the user's status fires off 401s and a
       spurious "Connection lost" banner right before the redirect
       to /login. -->
{:else}
  <ConnectionBanner />
  <AppLayout>
    {@render children()}
  </AppLayout>
  <!-- Always mounted so the DM→direct-post fallback can dispatch
       an open-composer event from /messages/new (where the FAB is
       hidden). The FAB itself stays hidden on messages/admin/settings. -->
  <PostComposer showFab={showComposer} />
  <!-- Global step-up challenge: any admin-gated call outside /admin
       (moderation panel on profiles, etc.) that 403s with
       auth.sudo_required lands here so the user can unlock without
       detouring through the admin dashboard. -->
  <SudoModal />
  <!-- `?` cheat sheet for the global keyboard shortcuts. -->
  <KeyboardShortcutsModal />
  {#if showOnboarding}
    <OnboardingModal onclose={() => { showOnboarding = false; }} />
  {/if}
{/if}
