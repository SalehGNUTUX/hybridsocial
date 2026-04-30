<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import StatsCard from '$lib/components/admin/StatsCard.svelte';
  import ServicePanel from '$lib/components/admin/ServicePanel.svelte';
  import { addToast } from '$lib/stores/toast.js';
  import { api } from '$lib/api/client.js';
  import { getDashboardStats, getRecentReports, getVerifications, approveVerification, rejectVerification } from '$lib/api/admin.js';
  import type { AdminDashboardStats, AdminReport } from '$lib/api/types.js';
  import type { VerificationRequest } from '$lib/api/admin.js';

  let stats: AdminDashboardStats | null = $state(null);
  let recentReports: AdminReport[] = $state([]);
  let pendingVerifications: VerificationRequest[] = $state([]);
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
      const [s, r, v] = await Promise.all([
        getDashboardStats(),
        getRecentReports(),
        getVerifications({ status: 'pending', limit: '10' }).catch(() => [])
      ]);
      stats = s;
      recentReports = r;
      pendingVerifications = v;
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

  function statusClass(status: string): string {
    switch (status) {
      case 'pending': return 'status-pending';
      case 'resolved': return 'status-resolved';
      case 'dismissed': return 'status-dismissed';
      default: return '';
    }
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
        label="Total Users"
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
      />
    {/if}
  </div>

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

  <div class="dashboard-panels">
    <section class="panel card">
      <h2 class="panel-title">Recent Reports</h2>
      {#if loading}
        <div class="panel-loading">
          {#each Array(3) as _}
            <div class="skeleton" style="height: 48px; margin-bottom: 8px"></div>
          {/each}
        </div>
      {:else if recentReports.length === 0}
        <p class="panel-empty">No open reports</p>
      {:else}
        <ul class="report-list">
          {#each recentReports as report (report.id)}
            <li class="report-item">
              <div class="report-info">
                <span class="report-category">{report.category}</span>
                <span class="report-target">@{report.target_account.handle}</span>
              </div>
              <div class="report-meta">
                <span class="report-status {statusClass(report.status)}">{report.status}</span>
                <span class="report-date">{formatDate(report.created_at)}</span>
              </div>
            </li>
          {/each}
        </ul>
        <a href="/admin/moderation" class="panel-link">View all reports</a>
      {/if}
    </section>

    <section class="panel card">
      <h2 class="panel-title">Quick Actions</h2>
      <div class="quick-actions">
        <a href="/admin/users" class="quick-action-btn btn btn-outline">Manage Users</a>
        <a href="/admin/moderation" class="quick-action-btn btn btn-outline">Review Reports</a>
        <a href="/admin/federation" class="quick-action-btn btn btn-outline">Federation Status</a>
        <a href="/admin/theme" class="quick-action-btn btn btn-outline">Theme & Branding</a>
        <a href="/admin/announcements" class="quick-action-btn btn btn-outline">Announcements</a>
      </div>
    </section>
  </div>

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

  .dashboard-panels {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: var(--space-4);
  }

  .panel-title {
    font-size: var(--text-lg);
    font-weight: 600;
    margin-block-end: var(--space-4);
  }

  .panel-empty {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    text-align: center;
    padding: var(--space-6) 0;
  }

  .panel-loading {
    padding: var(--space-2) 0;
  }

  .report-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .report-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: var(--space-2) var(--space-3);
    background: var(--color-surface);
    border-radius: var(--radius-md);
    font-size: var(--text-sm);
  }

  .report-info {
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }

  .report-category {
    font-weight: 600;
  }

  .report-target {
    color: var(--color-text-secondary);
  }

  .report-meta {
    display: flex;
    align-items: center;
    gap: var(--space-3);
  }

  .report-status {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
  }

  .status-pending {
    background: var(--color-warning-soft);
    color: #92400e;
  }

  .status-resolved {
    background: var(--color-success-soft);
    color: #166534;
  }

  .status-dismissed {
    background: var(--color-surface);
    color: var(--color-text-secondary);
  }

  .report-date {
    color: var(--color-text-tertiary);
    font-size: var(--text-xs);
  }

  .panel-link {
    display: block;
    text-align: center;
    margin-block-start: var(--space-3);
    font-size: var(--text-sm);
    color: var(--color-primary);
  }

  .quick-actions {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
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

  .quick-action-btn {
    text-align: center;
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
    .dashboard-panels {
      grid-template-columns: 1fr;
    }

    .stats-grid {
      grid-template-columns: repeat(2, 1fr);
    }

    .services-grid {
      grid-template-columns: 1fr;
    }
  }
</style>
