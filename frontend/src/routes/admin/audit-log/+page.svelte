<script lang="ts">
  import { onMount } from 'svelte';
  import DataTable from '$lib/components/admin/DataTable.svelte';
  import Modal from '$lib/components/ui/Modal.svelte';
  import { addToast } from '$lib/stores/toast.js';
  import { getAuditLog } from '$lib/api/admin.js';
  import type { AuditLogEntry } from '$lib/api/types.js';

  let entries: AuditLogEntry[] = $state([]);
  let loading = $state(true);
  let sortKey = $state('created_at');
  let sortDir = $state<'asc' | 'desc'>('desc');

  // Filters
  let actionFilter = $state('');
  let actorFilter = $state('');
  let dateFrom = $state('');
  let dateTo = $state('');

  // Detail modal
  let detailOpen = $state(false);
  let detailEntry: AuditLogEntry | null = $state(null);

  const columns = [
    { key: 'actor', label: 'Actor' },
    { key: 'action', label: 'Action', sortable: true },
    { key: 'target', label: 'Target' },
    { key: 'created_at', label: 'Date', sortable: true },
    { key: 'details', label: 'Details' }
  ];

  let filteredEntries = $derived(
    entries.filter((e) => {
      if (actionFilter && !e.action.toLowerCase().includes(actionFilter.toLowerCase())) return false;
      if (actorFilter) {
        const handle = e.actor?.handle?.toLowerCase() ?? 'system';
        if (!handle.includes(actorFilter.toLowerCase())) return false;
      }
      if (dateFrom) {
        const from = new Date(dateFrom);
        if (new Date(e.created_at) < from) return false;
      }
      if (dateTo) {
        const to = new Date(dateTo);
        to.setDate(to.getDate() + 1);
        if (new Date(e.created_at) > to) return false;
      }
      return true;
    })
  );

  let tableRows = $derived(
    filteredEntries.map((e) => ({ ...e, _entry: e } as Record<string, unknown>))
  );

  onMount(async () => {
    try {
      const result = await getAuditLog();
      entries = result.data;
    } catch {
      addToast('Failed to load audit log', 'error');
    } finally {
      loading = false;
    }
  });

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    });
  }

  // Compact one-line summary of the details blob, with key values
  // inlined so the row shows something useful before you open the
  // modal. Strings are truncated to avoid blowing up row height.
  function summarizeDetails(details: Record<string, unknown> | null): string {
    if (!details) return '';
    const pairs = Object.entries(details).filter(([, v]) => v != null && v !== '');
    if (pairs.length === 0) return '';
    return pairs
      .map(([k, v]) => {
        const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
        const trimmed = s.length > 40 ? s.slice(0, 40) + '…' : s;
        return `${k}: ${trimmed}`;
      })
      .join(' · ');
  }

  function actorLabel(e: AuditLogEntry): string {
    if (!e.actor) return 'system';
    return '@' + e.actor.handle;
  }

  function actorLink(e: AuditLogEntry): string | null {
    return e.actor ? `/@${e.actor.handle}` : null;
  }

  function targetLabel(e: AuditLogEntry): string {
    if (e.target?.label) return e.target.label;
    if (e.target_type) {
      // No backend resolver for this target_type — fall back to
      // showing the raw type and id so the row isn't empty.
      const shortId = e.target_id ? e.target_id.slice(0, 8) : '';
      return shortId ? `${e.target_type} #${shortId}` : e.target_type;
    }
    return '—';
  }

  function actionClass(action: string): string {
    if (action.endsWith('.deleted') || action.endsWith('.suspended') || action.endsWith('.banned') || action.endsWith('.rejected') || action.endsWith('.failed')) {
      return 'action-danger';
    }
    if (action.endsWith('.created') || action.endsWith('.approved') || action.endsWith('.resolved') || action.endsWith('.restored') || action.endsWith('.unsuspended')) {
      return 'action-success';
    }
    if (action.startsWith('auth.')) return 'action-auth';
    return 'action-neutral';
  }

  function openDetail(entry: AuditLogEntry) {
    detailEntry = entry;
    detailOpen = true;
  }

  function prettyJson(obj: unknown): string {
    try {
      return JSON.stringify(obj, null, 2);
    } catch {
      return String(obj);
    }
  }
</script>

<svelte:head>
  <title>Audit Log - Admin</title>
</svelte:head>

<div class="audit-page">
  <h1 class="page-title">Audit Log</h1>
  <p class="page-hint">Click any row to see the full event, including the metadata JSON and IP address.</p>

  <div class="filters">
    <input
      type="text"
      class="input"
      placeholder="Filter by action (e.g. account.suspended)…"
      bind:value={actionFilter}
    />
    <input
      type="text"
      class="input"
      placeholder="Filter by actor handle…"
      bind:value={actorFilter}
    />
    <input
      type="date"
      class="input date-input"
      bind:value={dateFrom}
      aria-label="From date"
    />
    <input
      type="date"
      class="input date-input"
      bind:value={dateTo}
      aria-label="To date"
    />
  </div>

  <DataTable
    {columns}
    rows={tableRows}
    bind:sortKey
    bind:sortDir
    {loading}
    emptyMessage="No audit log entries found"
  >
    {#snippet rowContent(row)}
      {@const entry = row['_entry'] as AuditLogEntry}
      <td onclick={() => openDetail(entry)} class="clickable">
        {#if entry.actor}
          <div class="actor-cell">
            {#if entry.actor.avatar_url}
              <img src={entry.actor.avatar_url} alt="" class="actor-avatar" />
            {:else}
              <span class="actor-avatar actor-avatar-fallback">{entry.actor.handle.charAt(0).toUpperCase()}</span>
            {/if}
            <span class="actor-handle">@{entry.actor.handle}</span>
          </div>
        {:else}
          <span class="actor-system">system</span>
        {/if}
      </td>
      <td onclick={() => openDetail(entry)} class="clickable">
        <span class="action-label {actionClass(entry.action)}">{entry.action}</span>
      </td>
      <td onclick={() => openDetail(entry)} class="clickable">
        <span class="target-label">{targetLabel(entry)}</span>
      </td>
      <td onclick={() => openDetail(entry)} class="clickable">
        <time datetime={entry.created_at} class="date-cell">{formatDate(entry.created_at)}</time>
      </td>
      <td onclick={() => openDetail(entry)} class="clickable">
        <span class="details-text">{summarizeDetails(entry.details)}</span>
      </td>
    {/snippet}
  </DataTable>
</div>

<Modal bind:open={detailOpen} title="Audit log entry">
  {#if detailEntry}
    {@const entry = detailEntry}
    <dl class="detail-grid">
      <dt>Actor</dt>
      <dd>
        {#if entry.actor}
          <a href={actorLink(entry)!} class="detail-link">{actorLabel(entry)}</a>
          {#if entry.actor.display_name}
            <span class="detail-secondary">· {entry.actor.display_name}</span>
          {/if}
        {:else}
          <span class="detail-secondary">system (pre-authentication or automated)</span>
        {/if}
      </dd>

      <dt>Action</dt>
      <dd><span class="action-label {actionClass(entry.action)}">{entry.action}</span></dd>

      {#if entry.target_type || entry.target}
        <dt>Target</dt>
        <dd>
          <div class="target-block">
            <span class="target-label">{targetLabel(entry)}</span>
            {#if entry.target?.deleted}
              <span class="target-deleted">(deleted)</span>
            {/if}
          </div>
          {#if entry.target?.excerpt}
            <div class="target-excerpt">"{entry.target.excerpt}"</div>
          {/if}
          <div class="detail-secondary detail-mono">
            {entry.target_type ?? '—'} · {entry.target_id ?? '—'}
          </div>
        </dd>
      {/if}

      <dt>When</dt>
      <dd>
        <div>{formatDate(entry.created_at)}</div>
        <div class="detail-secondary detail-mono">{entry.created_at}</div>
      </dd>

      {#if entry.ip_address}
        <dt>IP</dt>
        <dd class="detail-mono">{entry.ip_address}</dd>
      {/if}

      <dt>Metadata</dt>
      <dd>
        {#if entry.details && Object.keys(entry.details).length > 0}
          <pre class="json-block">{prettyJson(entry.details)}</pre>
        {:else}
          <span class="detail-secondary">(empty)</span>
        {/if}
      </dd>
    </dl>

    <div class="modal-actions">
      <button class="btn btn-primary" type="button" onclick={() => (detailOpen = false)}>Close</button>
    </div>
  {/if}
</Modal>

<style>
  .audit-page {
    max-width: 1200px;
  }

  .page-title {
    font-size: var(--text-2xl);
    font-weight: 700;
    margin-block-end: var(--space-2);
  }

  .page-hint {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    margin-block-end: var(--space-6);
  }

  .filters {
    display: flex;
    gap: var(--space-2);
    margin-block-end: var(--space-4);
    flex-wrap: wrap;
  }

  .filters .input {
    flex: 1;
    min-width: 150px;
  }

  .date-input {
    max-width: 160px;
  }

  .clickable {
    cursor: pointer;
  }

  /* Give audit rows more breathing room than the default DataTable
     padding — five columns of technical content is dense, and
     clickable rows benefit from a larger hit target. */
  .audit-page :global(.data-table td) {
    padding: var(--space-5) var(--space-4);
    line-height: 1.5;
  }

  .audit-page :global(.data-table th) {
    padding-block: var(--space-4);
  }

  .actor-cell {
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }

  .actor-avatar {
    width: 24px;
    height: 24px;
    border-radius: var(--radius-full);
    flex-shrink: 0;
    object-fit: cover;
  }

  .actor-avatar-fallback {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--color-secondary-container);
    color: var(--color-primary);
    font-weight: 700;
    font-size: var(--text-xs);
  }

  .actor-handle {
    font-weight: 600;
    font-size: var(--text-sm);
  }

  .actor-system {
    font-size: var(--text-sm);
    color: var(--color-text-tertiary);
    font-style: italic;
  }

  .action-label {
    display: inline-block;
    font-size: var(--text-xs);
    font-family: var(--font-mono);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-sm);
    white-space: nowrap;
  }

  .action-success {
    background: var(--color-success-soft);
    color: var(--color-on-success-soft);
  }

  .action-danger {
    background: var(--color-danger-soft);
    color: var(--color-on-danger-soft);
  }

  .action-auth {
    background: var(--color-info-soft);
    color: var(--color-on-info-soft);
  }

  .action-neutral {
    background: var(--color-surface);
    color: var(--color-text-secondary);
  }

  .target-label {
    font-size: var(--text-sm);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 260px;
    display: inline-block;
    vertical-align: middle;
  }

  .target-deleted {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
    margin-inline-start: var(--space-1);
    font-style: italic;
  }

  .target-excerpt {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    font-style: italic;
    margin-block-start: 2px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 360px;
  }

  .date-cell {
    font-size: var(--text-sm);
    white-space: nowrap;
    color: var(--color-text-secondary);
  }

  .details-text {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    max-width: 280px;
    display: inline-block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    vertical-align: middle;
  }

  /* Detail modal */
  .detail-grid {
    display: grid;
    grid-template-columns: 96px 1fr;
    gap: var(--space-3) var(--space-4);
    margin: 0 0 var(--space-4) 0;
  }

  .detail-grid dt {
    font-weight: 600;
    color: var(--color-text-secondary);
    font-size: var(--text-xs);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding-block-start: 2px;
  }

  .detail-grid dd {
    margin: 0;
    font-size: var(--text-sm);
    min-width: 0;
  }

  .detail-link {
    color: var(--color-primary);
    font-weight: 600;
    text-decoration: none;
  }

  .detail-link:hover {
    text-decoration: underline;
  }

  .detail-secondary {
    color: var(--color-text-tertiary);
    font-size: var(--text-xs);
  }

  .detail-mono {
    font-family: var(--font-mono);
  }

  .target-block {
    display: flex;
    align-items: baseline;
    gap: var(--space-1);
    flex-wrap: wrap;
  }

  .target-block .target-label {
    max-width: none;
    white-space: normal;
  }

  .json-block {
    font-family: var(--font-mono);
    font-size: var(--text-xs);
    background: var(--color-surface);
    border-radius: var(--radius-md);
    padding: var(--space-3);
    max-height: 280px;
    overflow: auto;
    white-space: pre-wrap;
    word-break: break-word;
    margin: 0;
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
  }

  @media (max-width: 768px) {
    .filters {
      flex-direction: column;
    }

    .filters .input,
    .date-input {
      max-width: none;
    }

    .detail-grid {
      grid-template-columns: 1fr;
      gap: var(--space-2);
    }

    .detail-grid dt {
      margin-block-start: var(--space-2);
    }
  }
</style>
