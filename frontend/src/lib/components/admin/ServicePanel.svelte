<script lang="ts">
  import Sparkline from './Sparkline.svelte';
  import { api } from '$lib/api/client.js';

  type SeriesPoint = { t: string; v: number };
  type SummaryRow = {
    service: string;
    metric: string;
    latest: { t: string; v: number };
    sparkline: SeriesPoint[];
  };

  type ServiceHealth = {
    status?: string;
    version?: string;
    uptime_seconds?: number;
    error?: string;
    cluster_health?: string;
    backend?: string;
  };

  let {
    title,
    icon,
    service,
    metrics,
    rows,
    health,
  }: {
    title: string;
    icon: string;
    service: string;
    /** Display rows: which metric keys to show, in what order, and how to format. */
    metrics: { key: string; label: string; format: (v: number) => string }[];
    rows: SummaryRow[];
    health?: ServiceHealth | null;
  } = $props();

  function formatUptime(seconds: number | undefined): string {
    if (!seconds) return '';
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    if (days > 0) return `${days}d ${hours}h`;
    if (hours > 0) return `${hours}h ${mins}m`;
    return `${mins}m`;
  }

  let byMetric = $derived.by(() => {
    const m: Record<string, SummaryRow> = {};
    for (const r of rows) {
      if (r.service === service) m[r.metric] = r;
    }
    return m;
  });

  // Show "no data yet" if the collector hasn't run, or if every metric
  // for this service is missing. Probes that intentionally skip (e.g.
  // OpenSearch on a Postgres-search instance) hit this path.
  let hasAnyData = $derived(metrics.some((m) => byMetric[m.key]));

  // Headline status, derived from the live dashboard probe + presence
  // of collector samples. The dashboard probe is authoritative for
  // up/down — the collector lags it by up to one tick — so a freshly
  // dead service stays correct without waiting for the next sweep.
  type StatusKind = 'operational' | 'degraded' | 'offline' | 'not_configured' | 'no_data';
  let statusKind = $derived.by<StatusKind>(() => {
    const s = health?.status;
    if (s === 'not_configured') return 'not_configured';
    if (s === 'down') return 'offline';
    if (s === 'degraded') return 'degraded';
    if (hasAnyData) return 'operational';
    return 'no_data';
  });

  let statusLabel = $derived(
    {
      operational: 'operational',
      degraded: 'degraded',
      offline: 'offline',
      not_configured: 'not configured',
      no_data: 'collecting',
    }[statusKind],
  );

  let expanded = $state<{ key: string; label: string } | null>(null);
  let expandedSeries = $state<SeriesPoint[] | null>(null);
  let expandedWindow = $state<'1h' | '6h' | '24h' | '7d' | '30d'>('1h');
  let expandedLoading = $state(false);

  async function loadExpandedSeries() {
    if (!expanded) return;
    expandedLoading = true;
    try {
      const res = await api.get<{ samples: SeriesPoint[] }>('/api/v1/admin/metrics/series', {
        service,
        metric: expanded.key,
        window: expandedWindow,
      });
      expandedSeries = res.samples;
    } catch {
      expandedSeries = [];
    } finally {
      expandedLoading = false;
    }
  }

  function openExpanded(key: string, label: string) {
    expanded = { key, label };
    expandedSeries = null;
    expandedWindow = '1h';
    loadExpandedSeries();
  }

  function closeExpanded() {
    expanded = null;
    expandedSeries = null;
  }

  function changeWindow(w: typeof expandedWindow) {
    expandedWindow = w;
    loadExpandedSeries();
  }
</script>

<section class="service-panel">
  <header class="service-panel-header">
    <span class="material-symbols-outlined service-panel-icon" aria-hidden="true">{icon}</span>
    <h3 class="service-panel-title">{title}</h3>
    <span
      class="service-panel-status"
      class:status-up={statusKind === 'operational'}
      class:status-degraded={statusKind === 'degraded'}
      class:status-down={statusKind === 'offline'}
      class:status-stale={statusKind === 'no_data' || statusKind === 'not_configured'}
    >
      {statusLabel}
    </span>
  </header>
  {#if health?.version || health?.uptime_seconds}
    <div class="service-panel-meta">
      {#if health.version}<span class="service-panel-version">v{health.version}</span>{/if}
      {#if health.uptime_seconds}<span class="service-panel-uptime">up {formatUptime(health.uptime_seconds)}</span>{/if}
    </div>
  {/if}
  {#if health?.error && statusKind !== 'operational'}
    <div class="service-panel-error">{health.error}</div>
  {/if}
  {#if statusKind === 'not_configured'}
    <p class="service-panel-note">
      Not running on this instance. Search currently uses PostgreSQL.
    </p>
  {/if}
  <div class="service-panel-rows">
    {#each metrics as m (m.key)}
      {@const row = byMetric[m.key]}
      <button
        type="button"
        class="service-panel-row"
        onclick={() => openExpanded(m.key, m.label)}
        disabled={!row}
      >
        <span class="row-label">{m.label}</span>
        <span class="row-value">{row ? m.format(row.latest.v) : '—'}</span>
        <span class="row-spark">
          {#if row && row.sparkline && row.sparkline.length > 1}
            <Sparkline points={row.sparkline} width={100} height={24} />
          {/if}
        </span>
      </button>
    {/each}
  </div>
</section>

{#if expanded}
  <div class="metric-modal-overlay" role="dialog" aria-modal="true" onclick={closeExpanded}>
    <div class="metric-modal" onclick={(e) => e.stopPropagation()}>
      <header class="metric-modal-header">
        <h3 class="metric-modal-title">{title} · {expanded.label}</h3>
        <button class="metric-modal-close" onclick={closeExpanded} aria-label="Close">
          <span class="material-symbols-outlined">close</span>
        </button>
      </header>
      <nav class="metric-modal-windows" aria-label="Time window">
        {#each ['1h', '6h', '24h', '7d', '30d'] as const as w (w)}
          <button
            type="button"
            class="window-btn"
            class:window-btn-active={expandedWindow === w}
            onclick={() => changeWindow(w)}
          >
            {w}
          </button>
        {/each}
      </nav>
      <div class="metric-modal-chart">
        {#if expandedLoading}
          <p class="metric-modal-loading">Loading…</p>
        {:else if !expandedSeries || expandedSeries.length === 0}
          <p class="metric-modal-empty">No data for this window yet.</p>
        {:else}
          <Sparkline points={expandedSeries} width={640} height={220} />
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .service-panel {
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl, 16px);
    padding: 16px 18px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .service-panel-header {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .service-panel-icon {
    font-size: 22px;
    color: var(--color-primary);
  }

  .service-panel-title {
    margin: 0;
    font-size: 1rem;
    font-weight: 700;
    flex: 1;
    color: var(--color-text);
  }

  .service-panel-status {
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-weight: 700;
    padding: 2px 8px;
    border-radius: 9999px;
  }

  .status-up {
    background: var(--color-success-soft, rgba(34, 197, 94, 0.15));
    color: var(--color-success, #16a34a);
  }

  .status-degraded {
    background: rgba(234, 179, 8, 0.15);
    color: #b45309;
  }

  .status-down {
    background: rgba(239, 68, 68, 0.15);
    color: var(--color-danger, #dc2626);
  }

  .status-stale {
    background: var(--color-surface-container-high, rgba(0, 0, 0, 0.06));
    color: var(--color-text-tertiary);
  }

  .service-panel-meta {
    display: flex;
    gap: 10px;
    font-size: 0.75rem;
    color: var(--color-text-tertiary);
    margin-block-start: -4px;
  }

  .service-panel-version,
  .service-panel-uptime {
    font-variant-numeric: tabular-nums;
  }

  .service-panel-error {
    font-size: 0.75rem;
    color: var(--color-danger, #dc2626);
    background: rgba(239, 68, 68, 0.08);
    padding: 6px 10px;
    border-radius: 8px;
  }

  .service-panel-note {
    font-size: 0.8125rem;
    color: var(--color-text-secondary);
    margin: 0;
    line-height: 1.4;
  }

  .service-panel-rows {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .service-panel-row {
    display: grid;
    /* Sparkline column collapses to 0 when there's no time-series (e.g.
       OpenSearch snapshot metrics), so the value gets the full width
       instead of being crowded by an empty/placeholder chart. */
    grid-template-columns: 1fr auto minmax(0, 100px);
    align-items: center;
    gap: 12px;
    padding: 8px 10px;
    background: transparent;
    border: 1px solid transparent;
    border-radius: 10px;
    cursor: pointer;
    color: inherit;
    text-align: start;
    font: inherit;
  }

  .service-panel-row:hover:not(:disabled) {
    background: var(--color-surface-hover, rgba(0, 0, 0, 0.03));
    border-color: var(--color-border);
  }

  .service-panel-row:disabled {
    cursor: default;
    opacity: 0.5;
  }

  .row-label {
    font-size: 0.8125rem;
    color: var(--color-text-secondary);
  }

  .row-value {
    font-size: 0.95rem;
    font-weight: 700;
    color: var(--color-text);
    font-variant-numeric: tabular-nums;
  }

  .row-spark {
    display: inline-flex;
    align-items: center;
  }

  .metric-modal-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.55);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1100;
    padding: 16px;
  }

  .metric-modal {
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl, 16px);
    padding: 20px;
    max-width: 760px;
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .metric-modal-header {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .metric-modal-title {
    margin: 0;
    font-size: 1.05rem;
    font-weight: 700;
    flex: 1;
  }

  .metric-modal-close {
    background: transparent;
    border: none;
    color: var(--color-text-secondary);
    cursor: pointer;
    border-radius: 9999px;
    width: 32px;
    height: 32px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }

  .metric-modal-close:hover {
    background: var(--color-surface-hover, rgba(0, 0, 0, 0.04));
    color: var(--color-text);
  }

  .metric-modal-windows {
    display: flex;
    gap: 6px;
  }

  .window-btn {
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: 9999px;
    padding: 4px 12px;
    font-size: 0.8125rem;
    cursor: pointer;
    color: var(--color-text-secondary);
    font: inherit;
  }

  .window-btn-active {
    background: var(--color-primary);
    border-color: var(--color-primary);
    color: white;
  }

  .metric-modal-chart {
    min-height: 220px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .metric-modal-loading,
  .metric-modal-empty {
    color: var(--color-text-tertiary);
    font-size: 0.875rem;
  }
</style>
