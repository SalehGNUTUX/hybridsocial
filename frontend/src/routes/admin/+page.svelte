<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import StatsCard from '$lib/components/admin/StatsCard.svelte';
  import ServicePanel from '$lib/components/admin/ServicePanel.svelte';
  import { addToast } from '$lib/stores/toast.js';
  import { api } from '$lib/api/client.js';
  import { getDashboardStats, getVerifications, approveVerification, rejectVerification } from '$lib/api/admin.js';
  import type { AdminDashboardStats } from '$lib/api/types.js';
  import type { VerificationRequest } from '$lib/api/admin.js';

  let stats: AdminDashboardStats | null = $state(null);
  let pendingVerifications: VerificationRequest[] = $state([]);
  let pendingApprovalsCount = $state(0);
  let pendingAppealsCount = $state(0);
  let loading = $state(true);

  // Historical service metrics (1h sparklines + latest values).
  // Polled separately from the dashboard summary so a slow probe
  // doesn't delay the rest of the page.
  type MetricRow = {
    service: string;
    metric: string;
    latest: { t: string; v: number };
    sparkline: { t: string; v: number }[];
  };
  let metricRows: MetricRow[] = $state([]);

  function fmtBytes(n: number): string {
    if (!Number.isFinite(n) || n <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    let v = n;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2) + ' ' + units[i];
  }
  function fmtInt(n: number): string {
    return Math.round(n).toLocaleString();
  }
  function fmtRate(n: number, suffix = '/s'): string {
    return Math.round(n).toLocaleString() + suffix;
  }
  function fmtPct(n: number): string {
    return (n * 100).toFixed(1) + '%';
  }
  function fmtClusterStatus(n: number): string {
    return ['green', 'yellow', 'red'][Math.round(n)] ?? '?';
  }

  const pgMetrics = [
    { key: 'connections_active', label: 'Active conns', format: fmtInt },
    { key: 'connections_idle', label: 'Idle conns', format: fmtInt },
    { key: 'db_size_bytes', label: 'DB size', format: fmtBytes },
    { key: 'xact_commit', label: 'Commits/s', format: (v: number) => fmtRate(v) },
    { key: 'cache_hit_ratio', label: 'Cache hit', format: fmtPct },
  ];
  const valkeyMetrics = [
    { key: 'memory_used_bytes', label: 'Memory', format: fmtBytes },
    { key: 'memory_peak_bytes', label: 'Peak', format: fmtBytes },
    { key: 'total_keys', label: 'Keys', format: fmtInt },
    { key: 'connected_clients', label: 'Clients', format: fmtInt },
    { key: 'ops_per_sec', label: 'Ops/sec', format: (v: number) => fmtRate(v) },
    { key: 'evicted_keys', label: 'Evictions/s', format: (v: number) => fmtRate(v) },
  ];
  const natsMetrics = [
    { key: 'connections', label: 'Connections', format: fmtInt },
    { key: 'in_msgs', label: 'In msgs/s', format: (v: number) => fmtRate(v) },
    { key: 'out_msgs', label: 'Out msgs/s', format: (v: number) => fmtRate(v) },
    { key: 'jetstream_messages', label: 'JS messages', format: fmtInt },
    { key: 'jetstream_bytes', label: 'JS bytes', format: fmtBytes },
  ];
  const opensearchMetrics = [
    { key: 'cluster_status', label: 'Cluster', format: fmtClusterStatus },
    { key: 'index_count', label: 'Indices', format: fmtInt },
    { key: 'total_docs', label: 'Total docs', format: fmtInt },
    { key: 'index_size_bytes', label: 'Index size', format: fmtBytes },
    { key: 'unassigned_shards', label: 'Unassigned', format: fmtInt },
  ];

  async function loadMetrics() {
    try {
      const res = await api.get<{ services: MetricRow[] }>('/api/v1/admin/metrics/summary');
      metricRows = res.services || [];
    } catch {
      metricRows = [];
    }
  }

  let metricsTimer: ReturnType<typeof setInterval> | null = null;

  onMount(async () => {
    try {
      const [s, v, pa, ap] = await Promise.all([
        getDashboardStats(),
        getVerifications({ status: 'pending', limit: '10' }).catch(() => []),
        // Account-registration approvals are surfaced as a stats card
        // and link to /admin/user-management/approvals. We only need
        // the count, but the endpoint returns the full pending list —
        // the page is the authoritative actor view.
        api
          .get<{ data: { id: string }[] }>('/api/v1/admin/pending_accounts')
          .then((res) => (res.data || []).length)
          .catch(() => 0),
        // Pending suspension appeals — same dashboard pattern.
        api
          .get<{ data: { id: string }[] }>('/api/v1/admin/appeals', { status: 'pending' })
          .then((res) => (res.data || []).length)
          .catch(() => 0),
      ]);
      stats = s;
      pendingVerifications = v;
      pendingApprovalsCount = pa;
      pendingAppealsCount = ap;
    } catch (e) {
      addToast('Failed to load dashboard data', 'error');
    } finally {
      loading = false;
    }

    // Metrics summary is loaded after the main payload. The collector
    // ticks every 60s, so refreshing the dashboard at the same cadence
    // keeps the sparklines moving without piling on load.
    loadMetrics();
    metricsTimer = setInterval(loadMetrics, 60_000);
  });

  onDestroy(() => {
    if (metricsTimer) clearInterval(metricsTimer);
  });

  async function handleApproveVerification(id: string) {
    try {
      await approveVerification(id);
      pendingVerifications = pendingVerifications.filter(v => v.id !== id);
      addToast('Verification approved', 'success');
    } catch {
      addToast('Failed to approve verification', 'error');
    }
  }

  async function handleRejectVerification(id: string) {
    try {
      await rejectVerification(id);
      pendingVerifications = pendingVerifications.filter(v => v.id !== id);
      addToast('Verification rejected', 'success');
    } catch {
      addToast('Failed to reject verification', 'error');
    }
  }

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleDateString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  }

</script>

<svelte:head>
  <title>Admin Dashboard</title>
</svelte:head>

<div class="dashboard">
  <h1 class="page-title">Dashboard</h1>

  <div class="stats-grid">
    {#if loading}
      {#each Array(4) as _}
        <div class="card">
          <div class="skeleton" style="height: 16px; width: 60%; margin-bottom: 8px"></div>
          <div class="skeleton" style="height: 32px; width: 40%"></div>
        </div>
      {/each}
    {:else if stats}
      <StatsCard
        label="Local Users"
        value={stats.total_users.toLocaleString()}
        icon="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"
        href="/admin/users"
      />
      <StatsCard
        label="Total Posts"
        value={stats.total_posts.toLocaleString()}
        icon="M7 8h10M7 12h4m1 8l-4-4H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-3l-4 4z"
      />
      <StatsCard
        label="Known Instances"
        value={stats.known_instances.toLocaleString()}
        icon="M3.055 11H5a2 2 0 012 2v1a2 2 0 002 2 2 2 0 012 2v2.945M8 3.935V5.5A2.5 2.5 0 0010.5 8h.5a2 2 0 012 2 2 2 0 104 0 2 2 0 012-2h1.064M15 20.488V18a2 2 0 012-2h3.064M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
        href="/admin/federation"
      />
      <StatsCard
        label="Open Reports"
        value={stats.open_reports.toLocaleString()}
        icon="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.34 16.5c-.77.833.192 2.5 1.732 2.5z"
        href="/admin/moderation"
        alert={stats.open_reports > 0}
        alertLabel={`${stats.open_reports} open reports — needs attention`}
      />
      <StatsCard
        label="Approvals"
        value={pendingApprovalsCount.toLocaleString()}
        icon="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"
        href="/admin/user-management/approvals"
        alert={pendingApprovalsCount > 0}
        alertLabel={`${pendingApprovalsCount} pending approvals — needs attention`}
      />
      <StatsCard
        label="Appeals"
        value={pendingAppealsCount.toLocaleString()}
        icon="M3 6l3 1m0 0l-3 9a5.002 5.002 0 006.001 0M6 7l3 9M6 7l6-2m6 2l3-1m-3 1l-3 9a5.002 5.002 0 006.001 0M18 7l3 9m-3-9l-6-2m0-2v2m0 16V5m0 16H9m3 0h3"
        href="/admin/user-management/appeals"
        alert={pendingAppealsCount > 0}
        alertLabel={`${pendingAppealsCount} pending appeals — needs attention`}
      />
    {/if}
  </div>

  <section class="quick-actions-section">
    <h2 class="section-heading">Quick actions</h2>
    <div class="quick-actions-grid">
      {#each [
        { href: '/admin/user-management', icon: 'group', label: 'User management' },
        { href: '/admin/moderation', icon: 'gavel', label: 'Review reports' },
        { href: '/admin/federation', icon: 'hub', label: 'Federation' },
        { href: '/admin/theme', icon: 'palette', label: 'Theme & branding' },
        { href: '/admin/announcements', icon: 'campaign', label: 'Announcements' },
        { href: '/admin/email', icon: 'mail', label: 'Email' },
        { href: '/admin/tiers', icon: 'workspace_premium', label: 'Tiers' },
        { href: '/admin/audit-log', icon: 'list', label: 'Audit log' },
      ] as action (action.href)}
        <a href={action.href} class="quick-action-card card card-hover">
          <span class="material-symbols-outlined quick-action-icon" aria-hidden="true">{action.icon}</span>
          <span class="quick-action-label">{action.label}</span>
        </a>
      {/each}
    </div>
  </section>

  <section class="services-section metrics-section">
    <h2 class="section-heading">Service metrics</h2>
    <div class="metrics-grid">
      <ServicePanel
        title="PostgreSQL"
        icon="database"
        service="postgres"
        metrics={pgMetrics}
        rows={metricRows}
        health={stats?.services?.database ?? null}
      />
      <ServicePanel
        title="Valkey"
        icon="bolt"
        service="valkey"
        metrics={valkeyMetrics}
        rows={metricRows}
        health={stats?.services?.valkey ?? null}
      />
      <ServicePanel
        title="NATS"
        icon="hub"
        service="nats"
        metrics={natsMetrics}
        rows={metricRows}
        health={stats?.services?.nats ?? null}
      />
      <ServicePanel
        title="OpenSearch"
        icon="search"
        service="opensearch"
        metrics={opensearchMetrics}
        rows={metricRows}
        health={stats?.services?.opensearch ?? null}
      />
    </div>
  </section>

  <!-- Pending Verification Requests -->
  {#if pendingVerifications.length > 0}
    <section class="panel card verification-panel">
      <h2 class="panel-title">Pending Verification Requests</h2>
      <div class="verification-list">
        {#each pendingVerifications as req (req.id)}
          <div class="verification-item">
            <div class="verification-user">
              <div class="verification-avatar">
                {#if req.account?.avatar_url}
                  <img src={req.account.avatar_url} alt="" class="verification-img" />
                {:else}
                  <span class="verification-initial">{(req.account?.display_name || req.account?.handle || '?').charAt(0).toUpperCase()}</span>
                {/if}
              </div>
              <div class="verification-info">
                <span class="verification-name">{req.account?.display_name || req.account?.handle}</span>
                <span class="verification-handle">@{req.account?.handle}</span>
              </div>
            </div>
            <div class="verification-details">
              <span class="verification-type">{req.type}</span>
              {#if req.metadata?.reason}
                <p class="verification-reason">{req.metadata.reason}</p>
              {/if}
              {#if req.metadata?.domain}
                <p class="verification-reason">Domain: {req.metadata.domain}</p>
              {/if}
              <span class="verification-date">{formatDate(req.created_at)}</span>
            </div>
            <div class="verification-actions">
              <button class="btn btn-sm btn-primary" onclick={() => handleApproveVerification(req.id)}>Approve</button>
              <button class="btn btn-sm btn-outline" onclick={() => handleRejectVerification(req.id)}>Reject</button>
            </div>
          </div>
        {/each}
      </div>
    </section>
  {/if}
</div>

<style>
  .dashboard {
    max-width: 1100px;
  }

  .page-title {
    font-size: var(--text-2xl);
    font-weight: 700;
    margin-block-end: var(--space-6);
  }

  .stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: var(--space-4);
    margin-block-end: var(--space-6);
  }

  .panel-title {
    font-size: var(--text-lg);
    font-weight: 600;
    margin-block-end: var(--space-4);
  }

  /* Quick actions section: cards in the same visual family as
     StatsCard but icon-led + label only (no number). */
  .quick-actions-section {
    margin-block-end: var(--space-6);
  }

  .quick-actions-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: var(--space-3);
  }

  .quick-action-card {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-2);
    padding: var(--space-4);
    text-decoration: none;
    color: inherit;
  }

  .quick-action-card:hover {
    text-decoration: none;
  }

  .quick-action-icon {
    font-size: 24px;
    color: var(--color-primary);
  }

  .quick-action-label {
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-text);
  }

  /* Verification requests */
  .verification-panel {
    margin-block-start: var(--space-4);
  }

  .verification-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .verification-item {
    display: flex;
    align-items: flex-start;
    gap: var(--space-3);
    padding: var(--space-3);
    background: var(--color-surface);
    border-radius: var(--radius-lg);
  }

  .verification-user {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-shrink: 0;
  }

  .verification-avatar {
    width: 36px;
    height: 36px;
    border-radius: var(--radius-full);
    background: var(--color-primary-soft);
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    flex-shrink: 0;
  }

  .verification-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  .verification-initial {
    font-weight: 600;
    font-size: var(--text-sm);
    color: var(--color-primary);
  }

  .verification-info {
    display: flex;
    flex-direction: column;
  }

  .verification-name {
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-text);
  }

  .verification-handle {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
  }

  .verification-details {
    flex: 1;
    min-width: 0;
  }

  .verification-type {
    font-size: var(--text-xs);
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    color: var(--color-primary);
    background: var(--color-primary-soft);
    padding: 1px 6px;
    border-radius: var(--radius-full);
  }

  .verification-reason {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    margin-block-start: var(--space-1);
    line-height: 1.4;
  }

  .verification-date {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .verification-actions {
    display: flex;
    gap: var(--space-2);
    flex-shrink: 0;
  }

  .btn-sm {
    padding: var(--space-1) var(--space-3);
    font-size: var(--text-xs);
    border-radius: var(--radius-md);
  }

  .btn-primary {
    background: var(--color-primary);
    color: var(--color-text-on-primary);
    border: none;
    font-weight: 600;
    cursor: pointer;
  }

  .btn-primary:hover {
    background: var(--color-primary-hover);
  }

  /* Services */
  .services-section {
    margin-block-end: var(--space-6);
  }

  .section-heading {
    font-size: var(--text-lg);
    font-weight: 600;
    margin-block-end: var(--space-4);
  }

  .services-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: var(--space-3);
  }

  .metrics-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
    gap: var(--space-3);
  }


  .integration-note {
    font-style: italic;
    line-height: 1.4;
  }

  @media (max-width: 768px) {
    .stats-grid {
      grid-template-columns: repeat(2, 1fr);
    }

    .services-grid {
      grid-template-columns: 1fr;
    }
  }
</style>
