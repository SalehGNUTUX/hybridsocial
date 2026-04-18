<script lang="ts">
  import { onMount } from 'svelte';
  import Tabs from '$lib/components/ui/Tabs.svelte';
  import DataTable from '$lib/components/admin/DataTable.svelte';
  import { addToast } from '$lib/stores/toast.js';
  import {
    getReports, resolveReport, dismissReport,
    getContentFilters, createContentFilter, deleteContentFilter,
    getBannedDomains, banDomain, unbanDomain,
    getIpBlocks, createIpBlock, deleteIpBlock
  } from '$lib/api/admin.js';
  import type { AdminReport, ContentFilter, BannedDomain, IpBlock } from '$lib/api/types.js';

  const tabs = [
    { id: 'reports', label: 'Reports' },
    { id: 'filters', label: 'Content Filters' },
    { id: 'domains', label: 'Banned Domains' },
    { id: 'ipblocks', label: 'IP Blocks' }
  ];

  let activeTab = $state('reports');

  // Reports state
  let reports: AdminReport[] = $state([]);
  let reportsLoading = $state(true);
  let reportStatusFilter = $state('pending');

  let filteredReports = $derived(
    reportStatusFilter === 'all'
      ? reports
      : reports.filter((r) => r.status === reportStatusFilter)
  );

  let reportRows = $derived(
    filteredReports.map((r) => ({ ...r } as Record<string, unknown>))
  );

  // Content Filters state
  let filters: ContentFilter[] = $state([]);
  let filtersLoading = $state(false);
  let newFilterType = $state<'keyword' | 'regex' | 'domain'>('keyword');
  let newFilterPattern = $state('');
  let newFilterAction = $state<'warn' | 'hide' | 'reject'>('warn');
  let newFilterReplacement = $state('');
  let newFilterScope = $state<'all' | 'local' | 'remote'>('all');

  // Banned Domains state
  let bannedDomains: BannedDomain[] = $state([]);
  let domainsLoading = $state(false);
  let newDomain = $state('');
  let newDomainReason = $state('');

  // IP Blocks state
  let ipBlocks: IpBlock[] = $state([]);
  let ipBlocksLoading = $state(false);
  let filtersLoaded = $state(false);
  let domainsLoaded = $state(false);
  let ipBlocksLoaded = $state(false);
  let newIp = $state('');
  let newIpSubnetMask = $state('');
  let newIpReason = $state('');

  const reportColumns = [
    { key: 'category', label: 'Category', sortable: true },
    { key: 'target', label: 'Target' },
    { key: 'reporter', label: 'Reporter' },
    { key: 'content', label: 'What was reported' },
    { key: 'status', label: 'Status', sortable: true },
    { key: 'created_at', label: 'Date', sortable: true },
    { key: 'actions', label: 'Actions', width: '200px' }
  ];

  function stripTags(html: string | null | undefined): string {
    if (!html) return '';
    return html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
  }

  function truncate(s: string, n: number): string {
    return s.length > n ? s.slice(0, n).trim() + '…' : s;
  }

  onMount(async () => {
    await loadReports();
  });

  async function loadReports() {
    reportsLoading = true;
    try {
      const result = await getReports();
      reports = result.data;
    } catch {
      addToast('Failed to load reports', 'error');
    } finally {
      reportsLoading = false;
    }
  }

  async function loadFilters() {
    filtersLoading = true;
    try {
      filters = await getContentFilters();
    } catch {
      addToast('Failed to load content filters', 'error');
    } finally {
      filtersLoading = false;
      filtersLoaded = true;
    }
  }

  async function loadDomains() {
    domainsLoading = true;
    try {
      bannedDomains = await getBannedDomains();
    } catch {
      addToast('Failed to load banned domains', 'error');
    } finally {
      domainsLoading = false;
      domainsLoaded = true;
    }
  }

  async function loadIpBlocks() {
    ipBlocksLoading = true;
    try {
      ipBlocks = await getIpBlocks();
    } catch {
      addToast('Failed to load IP blocks', 'error');
    } finally {
      ipBlocksLoading = false;
      ipBlocksLoaded = true;
    }
  }

  $effect(() => {
    if (activeTab === 'filters' && !filtersLoaded && !filtersLoading) {
      loadFilters();
    } else if (activeTab === 'domains' && !domainsLoaded && !domainsLoading) {
      loadDomains();
    } else if (activeTab === 'ipblocks' && !ipBlocksLoaded && !ipBlocksLoading) {
      loadIpBlocks();
    }
  });

  async function handleResolve(report: AdminReport) {
    try {
      await resolveReport(report.id);
      // Replace immutably so Svelte reliably re-derives filteredReports.
      reports = reports.map((r) =>
        r.id === report.id ? { ...r, status: 'resolved' as const } : r
      );
      addToast(
        reportStatusFilter === 'pending'
          ? 'Report resolved — moved to the Resolved filter'
          : 'Report resolved',
        'success'
      );
    } catch {
      addToast('Failed to resolve report', 'error');
    }
  }

  async function handleDismiss(report: AdminReport) {
    try {
      await dismissReport(report.id);
      reports = reports.map((r) =>
        r.id === report.id ? { ...r, status: 'dismissed' as const } : r
      );
      addToast(
        reportStatusFilter === 'pending'
          ? 'Report dismissed — moved to the Dismissed filter'
          : 'Report dismissed',
        'success'
      );
    } catch {
      addToast('Failed to dismiss report', 'error');
    }
  }

  async function handleAddFilter() {
    if (!newFilterPattern.trim()) return;
    try {
      const filter = await createContentFilter({
        type: newFilterType,
        pattern: newFilterPattern,
        action: newFilterAction,
        replacement: newFilterReplacement || null,
        scope: newFilterScope
      });
      filters = [...filters, filter];
      newFilterPattern = '';
      newFilterReplacement = '';
      addToast('Content filter created', 'success');
    } catch {
      addToast('Failed to create content filter', 'error');
    }
  }

  async function handleDeleteFilter(id: string) {
    try {
      await deleteContentFilter(id);
      filters = filters.filter((f) => f.id !== id);
      addToast('Content filter removed', 'success');
    } catch {
      addToast('Failed to remove content filter', 'error');
    }
  }

  async function handleBanDomain() {
    if (!newDomain.trim()) return;
    try {
      const domain = await banDomain(newDomain, newDomainReason || undefined);
      bannedDomains = [...bannedDomains, domain];
      newDomain = '';
      newDomainReason = '';
      addToast('Domain banned', 'success');
    } catch {
      addToast('Failed to ban domain', 'error');
    }
  }

  async function handleUnbanDomain(id: string) {
    try {
      await unbanDomain(id);
      bannedDomains = bannedDomains.filter((d) => d.id !== id);
      addToast('Domain unbanned', 'success');
    } catch {
      addToast('Failed to unban domain', 'error');
    }
  }

  async function handleAddIpBlock() {
    if (!newIp.trim()) return;
    try {
      const block = await createIpBlock({
        ip_address: newIp.trim(),
        subnet_mask: newIpSubnetMask.trim() || null,
        reason: newIpReason.trim() || null,
        expires_at: null
      });
      ipBlocks = [...ipBlocks, block];
      newIp = '';
      newIpSubnetMask = '';
      newIpReason = '';
      addToast('IP block created', 'success');
    } catch (e: any) {
      const msg = e?.body?.message || e?.body?.error_description || 'Failed to create IP block';
      addToast(msg, 'error');
    }
  }

  async function handleDeleteIpBlock(id: string) {
    try {
      await deleteIpBlock(id);
      ipBlocks = ipBlocks.filter((b) => b.id !== id);
      addToast('IP block removed', 'success');
    } catch {
      addToast('Failed to remove IP block', 'error');
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
  <title>Moderation - Admin</title>
</svelte:head>

<div class="moderation-page">
  <h1 class="page-title">Moderation</h1>

  <Tabs {tabs} bind:active={activeTab}>
    {#if activeTab === 'reports'}
      <div class="tab-toolbar">
        <select class="input" style="width: 160px" bind:value={reportStatusFilter}>
          <option value="all">All</option>
          <option value="pending">Pending</option>
          <option value="resolved">Resolved</option>
          <option value="dismissed">Dismissed</option>
        </select>
        <span class="retention-note" aria-live="polite">
          Resolved and dismissed reports are kept for 90 days, then deleted. Pending reports are never deleted automatically.
        </span>
      </div>

      <DataTable
        columns={reportColumns}
        rows={reportRows}
        loading={reportsLoading}
        emptyMessage="No reports found"
      >
        {#snippet rowContent(row)}
          {@const targetAccount = (row['target_account'] as Record<string, any>) ?? null}
          {@const reporter = (row['reporter'] as Record<string, any>) ?? null}
          {@const targetPost = (row['target_post'] as Record<string, any>) ?? null}
          {@const targetHandle = targetAccount?.acct || targetAccount?.handle || 'unknown'}
          {@const reporterHandle = reporter?.acct || reporter?.handle || 'unknown'}
          {@const reportComment = (row['comment'] || row['description']) as string | undefined}
          {@const postText = targetPost ? truncate(stripTags(targetPost.content_html || targetPost.content), 200) : ''}

          <td><span class="report-category">{(row['category'] as string).replace(/_/g, ' ')}</span></td>

          <td>
            {#if targetAccount?.id}
              <a href="/@{targetHandle}" class="report-account-link">@{targetHandle}</a>
            {:else}
              @{targetHandle}
            {/if}
          </td>

          <td>
            {#if reporter?.id}
              <a href="/@{reporterHandle}" class="report-account-link">@{reporterHandle}</a>
            {:else}
              @{reporterHandle}
            {/if}
          </td>

          <td class="report-content-cell">
            {#if reportComment}
              <div class="report-comment">
                <span class="report-meta-label">Reporter's note:</span>
                <span>{reportComment}</span>
              </div>
            {/if}
            {#if row['target_type'] === 'post'}
              {#if targetPost}
                <a
                  href={`/post/${targetPost.id}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="report-post-preview"
                >
                  {#if postText}
                    <span class="report-post-text">{postText}</span>
                  {:else}
                    <span class="report-post-empty">(no text — media only)</span>
                  {/if}
                  <span class="material-symbols-outlined report-post-open">open_in_new</span>
                </a>
                {#if targetPost.deleted_at}
                  <span class="report-deleted-badge">Post already deleted</span>
                {/if}
              {:else}
                <span class="report-post-missing">
                  Post not found (id: <code>{row['target_id']}</code>)
                </span>
              {/if}
            {:else if row['target_type'] === 'account' || row['target_type'] === 'user'}
              <span class="report-meta-label">Account report</span>
            {/if}
            {#if !reportComment && row['target_type'] !== 'post'}
              <span class="report-post-empty">—</span>
            {/if}
          </td>

          <td>
            <span class="status-badge status-{row['status']}">
              {row['status']}
            </span>
          </td>
          <td>{formatDate(row['created_at'] as string)}</td>
          <td>
            {#if row['status'] === 'pending'}
              <div class="action-buttons">
                <button
                  class="btn btn-sm btn-primary"
                  type="button"
                  onclick={() => handleResolve(row as unknown as AdminReport)}
                >Resolve</button>
                <button
                  class="btn btn-sm btn-ghost"
                  type="button"
                  onclick={() => handleDismiss(row as unknown as AdminReport)}
                >Dismiss</button>
              </div>
            {:else}
              <span class="text-secondary" style="font-size: var(--text-xs)">{row['status']}</span>
            {/if}
          </td>
        {/snippet}
      </DataTable>

    {:else if activeTab === 'filters'}
      <form class="add-form" onsubmit={(e) => { e.preventDefault(); handleAddFilter(); }}>
        <select class="input" bind:value={newFilterType} style="width: 120px">
          <option value="keyword">Keyword</option>
          <option value="regex">Regex</option>
          <option value="domain">Domain</option>
        </select>
        <input class="input" type="text" bind:value={newFilterPattern} placeholder="Pattern..." required />
        <select class="input" bind:value={newFilterAction} style="width: 100px">
          <option value="warn">Warn</option>
          <option value="hide">Hide</option>
          <option value="reject">Reject</option>
        </select>
        <select class="input" bind:value={newFilterScope} style="width: 120px">
          <option value="all">All posts</option>
          <option value="local">Local only</option>
          <option value="remote">Remote only</option>
        </select>
        <input class="input" type="text" bind:value={newFilterReplacement} placeholder="Replacement (optional)" />
        <button class="btn btn-primary" type="submit">Add</button>
      </form>

      <div class="list-items">
        {#each filters as filter (filter.id)}
          <div class="list-item card">
            <div class="list-item-info">
              <span class="badge-type">{filter.type}</span>
              <code class="filter-pattern">{filter.pattern}</code>
              <span class="badge-action badge-{filter.action}">{filter.action}</span>
              {#if filter.scope !== 'all'}
                <span class="badge-scope">{filter.scope}</span>
              {/if}
              {#if filter.replacement}
                <span class="text-secondary">- {filter.replacement}</span>
              {/if}
            </div>
            <button
              class="btn btn-sm btn-danger"
              type="button"
              onclick={() => handleDeleteFilter(filter.id)}
            >Remove</button>
          </div>
        {:else}
          <p class="empty-text">No content filters configured</p>
        {/each}
      </div>

    {:else if activeTab === 'domains'}
      <form class="add-form" onsubmit={(e) => { e.preventDefault(); handleBanDomain(); }}>
        <input class="input" type="text" bind:value={newDomain} placeholder="domain.example" required />
        <input class="input" type="text" bind:value={newDomainReason} placeholder="Reason (optional)" />
        <button class="btn btn-primary" type="submit">Ban Domain</button>
      </form>

      <div class="list-items">
        {#each bannedDomains as domain (domain.id)}
          <div class="list-item card">
            <div class="list-item-info">
              <strong>{domain.domain}</strong>
              {#if domain.reason}
                <span class="text-secondary">- {domain.reason}</span>
              {/if}
            </div>
            <button
              class="btn btn-sm btn-danger"
              type="button"
              onclick={() => handleUnbanDomain(domain.id)}
            >Unban</button>
          </div>
        {:else}
          <p class="empty-text">No banned domains</p>
        {/each}
      </div>

    {:else if activeTab === 'ipblocks'}
      <form class="add-form" onsubmit={(e) => { e.preventDefault(); handleAddIpBlock(); }}>
        <input class="input" type="text" bind:value={newIp} placeholder="IP address (IPv4 or IPv6)" required />
        <input class="input" type="text" bind:value={newIpSubnetMask} placeholder="CIDR (optional, e.g. 24)" style="width: 180px" />
        <input class="input" type="text" bind:value={newIpReason} placeholder="Reason (optional)" />
        <button class="btn btn-primary" type="submit">Block IP</button>
      </form>

      <div class="list-items">
        {#each ipBlocks as block (block.id)}
          <div class="list-item card">
            <div class="list-item-info">
              <code>{block.ip_address}{#if block.subnet_mask}/{block.subnet_mask}{/if}</code>
              {#if block.reason}
                <span class="text-secondary">- {block.reason}</span>
              {/if}
            </div>
            <button
              class="btn btn-sm btn-danger"
              type="button"
              onclick={() => handleDeleteIpBlock(block.id)}
            >Remove</button>
          </div>
        {:else}
          <p class="empty-text">No IP blocks</p>
        {/each}
      </div>
    {/if}
  </Tabs>
</div>

<style>
  .moderation-page {
    max-width: 1100px;
  }

  .page-title {
    font-size: var(--text-2xl);
    font-weight: 700;
    margin-block-end: var(--space-6);
  }

  .tab-toolbar {
    margin-block-end: var(--space-4);
    display: flex;
    align-items: center;
    gap: var(--space-4);
    flex-wrap: wrap;
  }

  .report-category {
    font-weight: 600;
    text-transform: capitalize;
  }

  .status-badge {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    text-transform: capitalize;
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

  .action-buttons {
    display: flex;
    gap: var(--space-2);
  }

  .add-form {
    display: flex;
    gap: var(--space-2);
    margin-block-end: var(--space-4);
    flex-wrap: wrap;
    align-items: flex-end;
  }

  .add-form .input {
    flex: 1;
    min-width: 150px;
  }

  .list-items {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .list-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
  }

  .list-item-info {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-wrap: wrap;
    font-size: var(--text-sm);
  }

  .badge-type {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    background: var(--color-info-soft);
    color: #1e40af;
    text-transform: uppercase;
  }

  .filter-pattern {
    font-size: var(--text-sm);
    background: var(--color-surface);
    padding: 2px var(--space-2);
    border-radius: var(--radius-sm);
  }

  .badge-action {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    text-transform: capitalize;
  }

  .badge-warn {
    background: var(--color-warning-soft);
    color: #92400e;
  }

  .badge-hide {
    background: var(--color-surface);
    color: var(--color-text-secondary);
  }

  .badge-reject {
    background: var(--color-danger-soft);
    color: #991b1b;
  }

  .badge-scope {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    background: var(--color-surface);
    color: var(--color-text-secondary);
    text-transform: capitalize;
  }

  .empty-text {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    text-align: center;
    padding: var(--space-6) 0;
  }

  .report-content-cell {
    max-width: 360px;
    padding-inline-start: var(--space-4) !important;
  }

  /* Widen the handle cells + keep the whole handle on one line so a
     long acct like @user@bassam.social can't collide with the next
     column's content. */
  :global(.data-table td:nth-child(2)),
  :global(.data-table td:nth-child(3)) {
    min-width: 140px;
    padding-inline-end: var(--space-6) !important;
  }

  .report-comment {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    line-height: 1.4;
    margin-block-end: 6px;
  }

  .report-meta-label {
    font-size: 0.65rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--color-text-tertiary);
    font-weight: 600;
    margin-inline-end: 4px;
  }

  .report-post-preview {
    display: flex;
    align-items: flex-start;
    gap: 6px;
    padding: 6px 8px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
    text-decoration: none;
    color: var(--color-text);
    font-size: var(--text-xs);
    line-height: 1.4;
    transition: background 0.15s ease, border-color 0.15s ease;
  }

  .report-post-preview:hover {
    background: var(--color-surface-container-low, var(--color-surface));
    border-color: var(--color-primary);
    text-decoration: none;
  }

  .report-post-text {
    flex: 1;
    display: -webkit-box;
    -webkit-line-clamp: 3;
    -webkit-box-orient: vertical;
    overflow: hidden;
    word-break: break-word;
  }

  .report-post-empty {
    color: var(--color-text-tertiary);
    font-style: italic;
    font-size: var(--text-xs);
  }

  .report-post-open {
    font-size: 14px !important;
    color: var(--color-text-tertiary);
    flex-shrink: 0;
  }

  .report-post-missing {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .report-post-missing code {
    font-size: 0.65rem;
  }

  .report-deleted-badge {
    display: inline-block;
    margin-block-start: 4px;
    padding: 2px 6px;
    font-size: 0.65rem;
    font-weight: 600;
    color: #991b1b;
    background: var(--color-danger-soft);
    border-radius: var(--radius-sm);
  }

  .retention-note {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
    line-height: 1.4;
    max-width: 480px;
  }

  .report-account-link {
    color: var(--color-primary);
    text-decoration: none;
    /* Never split a handle across a column boundary — keeps
       @long@domain.social from running into the next cell. */
    white-space: nowrap;
    overflow-wrap: normal;
    word-break: keep-all;
    display: inline-block;
    max-width: 100%;
  }

  .report-account-link:hover {
    text-decoration: underline;
  }
</style>
