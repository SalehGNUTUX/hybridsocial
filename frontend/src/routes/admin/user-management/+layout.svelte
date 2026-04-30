<script lang="ts">
  import { page } from '$app/state';
  import { onMount, onDestroy } from 'svelte';
  import { api } from '$lib/api/client.js';

  let { children } = $props();

  type Tab = {
    href: string;
    label: string;
    permission?: string;
  };

  const tabs: Tab[] = [
    { href: '/admin/user-management/users', label: 'Users' },
    { href: '/admin/user-management/approvals', label: 'Approvals' },
    { href: '/admin/user-management/appeals', label: 'Appeals' },
    { href: '/admin/user-management/registration', label: 'Registration' },
    { href: '/admin/user-management/tiers', label: 'Verification Tiers' },
    { href: '/admin/user-management/badges', label: 'Custom Badges' },
    { href: '/admin/user-management/premium-reactions', label: 'Premium Reactions' },
  ];

  // Counts driving the small alert pills next to Approvals / Appeals
  // tabs — match the dashboard's red-dot treatment so admins can see
  // urgency without leaving the section.
  let pendingApprovals = $state(0);
  let pendingAppeals = $state(0);
  let countsTimer: ReturnType<typeof setInterval> | null = null;

  async function loadCounts() {
    const [a, ap] = await Promise.all([
      api
        .get<{ data: { id: string }[] }>('/api/v1/admin/pending_accounts')
        .then((r) => (r.data || []).length)
        .catch(() => 0),
      api
        .get<{ data: { id: string }[] }>('/api/v1/admin/appeals', { status: 'pending' })
        .then((r) => (r.data || []).length)
        .catch(() => 0),
    ]);
    pendingApprovals = a;
    pendingAppeals = ap;
  }

  onMount(() => {
    loadCounts();
    countsTimer = setInterval(loadCounts, 60_000);
  });

  onDestroy(() => {
    if (countsTimer) clearInterval(countsTimer);
  });

  function badgeFor(tab: Tab): number {
    if (tab.href.endsWith('/approvals')) return pendingApprovals;
    if (tab.href.endsWith('/appeals')) return pendingAppeals;
    return 0;
  }

  function isActive(tab: Tab): boolean {
    return page.url.pathname === tab.href || page.url.pathname.startsWith(tab.href + '/');
  }
</script>

<div class="user-mgmt">
  <header class="user-mgmt-header">
    <h1 class="user-mgmt-title">User management</h1>
    <p class="user-mgmt-subtitle">
      All user-facing controls — accounts, approvals, appeals, registration,
      verification tiers, badges, and premium reactions.
    </p>
  </header>

  <nav class="user-mgmt-tabs" aria-label="User management sections">
    {#each tabs as tab (tab.href)}
      {@const count = badgeFor(tab)}
      <a
        href={tab.href}
        class="user-mgmt-tab"
        class:user-mgmt-tab-active={isActive(tab)}
        aria-current={isActive(tab) ? 'page' : undefined}
      >
        <span>{tab.label}</span>
        {#if count > 0}
          <span class="user-mgmt-tab-badge" title="{count} pending">{count}</span>
        {/if}
      </a>
    {/each}
  </nav>

  <div class="user-mgmt-content">
    {@render children()}
  </div>
</div>

<style>
  .user-mgmt {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .user-mgmt-header {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .user-mgmt-title {
    margin: 0;
    font-size: var(--text-2xl);
    font-weight: 700;
    color: var(--color-text);
  }

  .user-mgmt-subtitle {
    margin: 0;
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
  }

  .user-mgmt-tabs {
    display: flex;
    gap: 4px;
    flex-wrap: wrap;
    border-bottom: 1px solid var(--color-border);
    padding-bottom: 0;
  }

  .user-mgmt-tab {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    margin-bottom: -1px;
    color: var(--color-text-secondary);
    font-size: var(--text-sm);
    font-weight: 600;
    text-decoration: none;
    border-bottom: 2px solid transparent;
    border-radius: 6px 6px 0 0;
    transition: color 150ms ease, border-color 150ms ease, background 150ms ease;
  }

  .user-mgmt-tab:hover {
    color: var(--color-text);
    background: var(--color-surface-hover, rgba(0, 0, 0, 0.04));
  }

  .user-mgmt-tab-active {
    color: var(--color-primary);
    border-bottom-color: var(--color-primary);
  }

  .user-mgmt-tab-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 20px;
    height: 20px;
    padding: 0 6px;
    border-radius: 9999px;
    background: var(--color-danger, #dc2626);
    color: white;
    font-size: 0.7rem;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }

  .user-mgmt-content {
    padding-block-start: var(--space-2);
  }
</style>
