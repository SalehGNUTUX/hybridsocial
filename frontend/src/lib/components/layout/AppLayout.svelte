<script lang="ts">
  import type { Snippet } from 'svelte';
  import { page } from '$app/state';
  import Header from './Header.svelte';
  import Sidebar from './Sidebar.svelte';
  import RightSidebar from './RightSidebar.svelte';
  import BottomTabs from './BottomTabs.svelte';
  import AnnouncementBanner from './AnnouncementBanner.svelte';
  import AppBanner from './AppBanner.svelte';
  import Toast from '$lib/components/ui/Toast.svelte';

  let {
    children
  }: {
    children: Snippet;
  } = $props();

  const hideRightSidebarPaths = ['/settings', '/messages', '/admin'];
  const hideLeftSidebarPaths = ['/settings'];
  const fullWidthPaths = ['/messages', '/admin', '/settings'];

  let showRightSidebar = $derived(
    !hideRightSidebarPaths.some(p => page.url.pathname.startsWith(p))
  );

  let showLeftSidebar = $derived(
    !hideLeftSidebarPaths.some(p => page.url.pathname.startsWith(p))
  );

  let isFullWidth = $derived(
    fullWidthPaths.some(p => page.url.pathname.startsWith(p))
  );
</script>

<Header />
<div class="app-layout" class:no-right-sidebar={!showRightSidebar} class:no-left-sidebar={!showLeftSidebar}>
  {#if showLeftSidebar}
    <Sidebar />
  {/if}
  <main class="feed-column" class:full-width={isFullWidth}>
    <AppBanner />
    <AnnouncementBanner />
    {@render children()}
  </main>
  {#if showRightSidebar}
    <RightSidebar />
  {/if}
</div>
<BottomTabs />
<Toast />

<style>
  .app-layout {
    display: grid;
    grid-template-columns: var(--sidebar-width) minmax(0, 1fr) var(--right-sidebar-width);
    gap: var(--layout-gap);
    max-width: min(var(--layout-max-width), 100vw);
    margin: 0 auto;
    padding-top: calc(var(--header-height) + var(--space-8));
    padding-inline: var(--space-6);
    min-height: 100vh;
  }

  .app-layout.no-right-sidebar {
    grid-template-columns: var(--sidebar-width) minmax(0, 1fr);
  }

  .app-layout.no-left-sidebar {
    grid-template-columns: minmax(0, 1fr);
  }

  .app-layout.no-left-sidebar.no-right-sidebar {
    grid-template-columns: minmax(0, 1fr);
  }

  .feed-column {
    max-width: var(--feed-max-width);
    width: 100%;
    margin: 0 auto;
    /* Bottom breathing room so the last card on a long page doesn't
       sit flush against the viewport edge. The mobile breakpoint
       overrides this with a larger value to clear the BottomTabs bar. */
    padding: 0 0 var(--space-12) 0;
  }

  .feed-column.full-width {
    max-width: none;
  }

  /* Tablet: icon-only sidebar, no right sidebar */
  @media (max-width: 1280px) {
    .app-layout {
      grid-template-columns: 64px minmax(0, 1fr);
      gap: var(--space-4);
      padding-inline: var(--space-4);
    }

    .app-layout.no-right-sidebar {
      grid-template-columns: 64px minmax(0, 1fr);
    }

    .app-layout.no-left-sidebar {
      grid-template-columns: minmax(0, 1fr);
    }
  }

  /* Mobile: no sidebars, bottom tabs */
  @media (max-width: 768px) {
    .app-layout {
      grid-template-columns: 1fr;
      gap: 0;
      padding-inline: var(--space-3);
      padding-top: calc(var(--header-height) + var(--space-4));
      /* Belt-and-braces clip at the layout level too. The body-level
         clip should be enough, but on some Android/Chrome combos the
         body's overflow-x propagates to the viewport and the body
         itself stays wide — which let descendant overflow visibly
         escape the viewport. Clipping the layout container directly
         removes that escape hatch. */
      overflow-x: clip;
    }

    .feed-column {
      /* Force the main column to never be wider than its grid cell.
         Some descendants (stories carousels, code blocks, raw image
         attachments without max-width) used to push it past the
         viewport, which then visually cut off cards, tabs, and
         action buttons. */
      max-width: 100%;
      min-width: 0;
      /* Reserve space for the BottomTabs bar plus the iOS home-indicator
         safe-area, otherwise the last card on a long page gets hidden
         behind the tab bar on notched devices. */
      padding-block-end: calc(var(--header-height) + env(safe-area-inset-bottom, 0px) + var(--space-2));
    }

    /* Page-level wrappers: constrain explicitly so any inner element
       with `width: 100%` resolves to the viewport width minus layout
       padding. Each of these had `max-width: var(--feed-max-width)`
       (= 680px) at desktop, which on mobile leaves them un-bounded. */
    .feed-column > :global(*) {
      max-width: 100%;
    }
  }
</style>
