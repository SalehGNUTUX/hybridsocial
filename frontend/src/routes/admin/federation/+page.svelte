<script lang="ts">
  import { onMount } from 'svelte';
  import Tabs from '$lib/components/ui/Tabs.svelte';
  import DataTable from '$lib/components/admin/DataTable.svelte';
  import Modal from '$lib/components/ui/Modal.svelte';
  import { addToast } from '$lib/stores/toast.js';
  import {
    getKnownInstances,
    getFederationPolicies, createFederationPolicy, deleteFederationPolicy,
    purgeInstancePreview, purgeInstanceContent
  } from '$lib/api/admin.js';
  import { api } from '$lib/api/client.js';
  import Sparkline from '$lib/components/admin/Sparkline.svelte';
  import RelaysPanel from '$lib/components/admin/RelaysPanel.svelte';
  import type { KnownInstance, FederationPolicy, DeliveryQueueStats, InstancePurgePreview } from '$lib/api/types.js';

  const tabs = [
    { id: 'instances', label: 'Known Instances' },
    { id: 'policies', label: 'Policies' },
    { id: 'delivery', label: 'Delivery Queue' },
    { id: 'relays', label: 'Relays' }
  ];

  let activeTab = $state('instances');

  // Known Instances
  let instances: KnownInstance[] = $state([]);
  let instancesLoading = $state(true);
  let instanceSortKey = $state('last_activity_at');
  let instanceSortDir = $state<'asc' | 'desc'>('desc');

  let instanceRows = $derived(
    instances.map((i) => ({ ...i } as Record<string, unknown>))
  );

  const instanceColumns = [
    { key: 'domain', label: 'Domain', sortable: true },
    { key: 'software', label: 'Software' },
    { key: 'user_count', label: 'Users', sortable: true },
    { key: 'last_activity_at', label: 'Last Activity', sortable: true },
    { key: 'status', label: 'Status' }
  ];

  // Policies
  let policies: FederationPolicy[] = $state([]);
  let policiesLoading = $state(false);
  let newPolicyDomain = $state('');
  let newPolicyType = $state<'allow' | 'silence' | 'suspend' | 'force_nsfw' | 'block_media'>('silence');
  let newPolicyReason = $state('');

  // Delivery Queue
  // The Delivery Queue tab now reads from /admin/federation/delivery
  // which bundles three queries: queue snapshot, last-hour throughput
  // by activity type, and the top failing destination domains. Old
  // BEAM-stats blob (/admin/queue_stats) was misnamed — it was VM
  // metrics, not delivery metrics — so we drop it from this tab.
  type FederationDelivery = {
    queue: {
      pending: number;
      retrying: number;
      failed_24h: number;
      delivered_24h: number;
      oldest_pending_age_seconds: number;
    };
    throughput: {
      buckets: { t: string; total: number; by_type: Record<string, number> }[];
      totals_by_type: Record<string, number>;
    };
    top_failing: {
      domain: string;
      failures: number;
      last_error: string | null;
      last_attempt_at: string | null;
      max_attempts: number;
    }[];
  };
  let deliveryStats: FederationDelivery | null = $state(null);
  let deliveryLoading = $state(false);

  // Purge
  let purgeModalOpen = $state(false);
  let purgeDomain = $state('');
  let purgePreview: InstancePurgePreview | null = $state(null);
  let purgePreviewLoading = $state(false);
  let purging = $state(false);

  onMount(async () => {
    await loadInstances();
  });

  async function loadInstances() {
    instancesLoading = true;
    try {
      const result = await getKnownInstances();
      instances = Array.isArray(result.data) ? result.data : [];
    } catch {
      addToast('Failed to load instances', 'error');
      instances = [];
    } finally {
      instancesLoading = false;
    }
  }

  async function loadPolicies() {
    policiesLoading = true;
    try {
      policies = await getFederationPolicies();
    } catch {
      addToast('Failed to load policies', 'error');
    } finally {
      policiesLoading = false;
      policiesLoaded = true;
    }
  }

  async function loadDelivery() {
    deliveryLoading = true;
    try {
      deliveryStats = await api.get<FederationDelivery>('/api/v1/admin/federation/delivery');
    } catch {
      addToast('Failed to load delivery stats', 'error');
    } finally {
      deliveryLoading = false;
      deliveryLoaded = true;
    }
  }

  function formatAge(seconds: number): string {
    if (!seconds || seconds <= 0) return '—';
    if (seconds < 60) return `${seconds}s`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
    if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
    return `${Math.floor(seconds / 86_400)}d ${Math.floor((seconds % 86_400) / 3600)}h`;
  }

  function formatRelative(iso: string | null): string {
    if (!iso) return '—';
    const diff = Date.now() - new Date(iso).getTime();
    const sec = Math.max(0, Math.floor(diff / 1000));
    return formatAge(sec) + ' ago';
  }

  // Throughput series for the sparkline. The backend returns one row
  // per minute that had any deliveries, so we densify to 60 buckets
  // (one per minute) — missing minutes count as zero so the chart
  // doesn't telescope across gaps.
  let throughputSeries = $derived.by(() => {
    if (!deliveryStats?.throughput?.buckets?.length) return [] as { t: string; v: number }[];
    const buckets = deliveryStats.throughput.buckets;
    const byMinute = new Map<number, number>();
    for (const b of buckets) {
      byMinute.set(new Date(b.t).getTime(), b.total);
    }
    const now = Date.now();
    const start = Math.floor((now - 60 * 60_000) / 60_000) * 60_000;
    const out: { t: string; v: number }[] = [];
    for (let i = 0; i <= 60; i++) {
      const t = start + i * 60_000;
      out.push({ t: new Date(t).toISOString(), v: byMinute.get(t) ?? 0 });
    }
    return out;
  });

  // Activity-type chips ordered by count desc, six most common types.
  let typeBreakdown = $derived.by(() => {
    if (!deliveryStats?.throughput?.totals_by_type) return [] as { type: string; count: number }[];
    return Object.entries(deliveryStats.throughput.totals_by_type)
      .map(([type, count]) => ({ type, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 6);
  });

  let policiesLoaded = $state(false);
  let deliveryLoaded = $state(false);

  $effect(() => {
    if (activeTab === 'policies' && !policiesLoaded && !policiesLoading) {
      loadPolicies();
    } else if (activeTab === 'delivery' && !deliveryLoaded && !deliveryLoading) {
      loadDelivery();
    }
  });

  async function handleAddPolicy() {
    if (!newPolicyDomain.trim()) return;
    try {
      const policy = await createFederationPolicy({
        domain: newPolicyDomain,
        policy: newPolicyType,
        reason: newPolicyReason || null
      });
      policies = [...policies, policy];
      newPolicyDomain = '';
      newPolicyReason = '';
      addToast('Federation policy created', 'success');
    } catch {
      addToast('Failed to create policy', 'error');
    }
  }

  async function handleDeletePolicy(id: string) {
    try {
      await deleteFederationPolicy(id);
      policies = policies.filter((p) => p.id !== id);
      addToast('Policy removed', 'success');
    } catch {
      addToast('Failed to remove policy', 'error');
    }
  }


  async function openPurgeModal(domain: string) {
    purgeDomain = domain;
    purgePreview = null;
    purgeModalOpen = true;
    purgePreviewLoading = true;
    try {
      purgePreview = await purgeInstancePreview(domain);
    } catch {
      addToast('Failed to load purge preview', 'error');
    } finally {
      purgePreviewLoading = false;
    }
  }

  async function handlePurge() {
    if (!purgeDomain) return;
    purging = true;
    try {
      await purgeInstanceContent(purgeDomain);
      addToast(`Content from ${purgeDomain} purged`, 'success');
      purgeModalOpen = false;
      await loadInstances();
    } catch {
      addToast('Failed to purge instance content', 'error');
    } finally {
      purging = false;
    }
  }

  function isSuspended(domain: string): boolean {
    return policies.some((p) => p.domain === domain && p.policy === 'suspend');
  }

  function policyBadgeClass(policy: string): string {
    switch (policy) {
      case 'allow': return 'policy-allow';
      case 'silence': return 'policy-silence';
      case 'suspend': return 'policy-suspend';
      case 'force_nsfw': return 'policy-force_nsfw';
      case 'block_media': return 'policy-block_media';
      default: return '';
    }
  }

  function formatDate(iso: string | null): string {
    if (!iso) return 'Never';
    return new Date(iso).toLocaleDateString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  }
</script>

<svelte:head>
  <title>Federation - Admin</title>
</svelte:head>

<div class="federation-page">
  <h1 class="page-title">Federation</h1>

  <Tabs {tabs} bind:active={activeTab}>
    {#if activeTab === 'instances'}
      <DataTable
        columns={instanceColumns}
        rows={instanceRows}
        bind:sortKey={instanceSortKey}
        bind:sortDir={instanceSortDir}
        loading={instancesLoading}
        emptyMessage="No known instances"
      >
        {#snippet rowContent(row)}
          <td><strong>{row['domain']}</strong></td>
          <td>
            {#if row['software']}
              {row['software']}
              {#if row['software_version']}
                <span class="text-secondary"> {row['software_version']}</span>
              {/if}
            {:else}
              <span class="text-tertiary">Unknown</span>
            {/if}
          </td>
          <td>{(row['user_count'] as number).toLocaleString()}</td>
          <td>{formatDate(row['last_activity_at'] as string | null)}</td>
          <td>
            {#if row['status'] === 'none' || !row['status']}
              <span class="text-tertiary" title="No moderation policy applied">—</span>
            {:else}
              <span class="instance-status instance-{row['status']}">
                {(row['status'] as string).replace(/_/g, ' ')}
              </span>
            {/if}
          </td>
        {/snippet}
      </DataTable>

    {:else if activeTab === 'policies'}
      <form class="add-form" onsubmit={(e) => { e.preventDefault(); handleAddPolicy(); }}>
        <input class="input" type="text" bind:value={newPolicyDomain} placeholder="domain.example" required />
        <select class="input" bind:value={newPolicyType} style="width: 160px">
          <option value="allow">Allow</option>
          <option value="silence">Silence</option>
          <option value="suspend">Suspend</option>
          <option value="force_nsfw">Force NSFW</option>
          <option value="block_media">Block Media</option>
        </select>
        <input class="input" type="text" bind:value={newPolicyReason} placeholder="Reason (optional)" />
        <button class="btn btn-primary" type="submit">Add Policy</button>
      </form>

      <div class="policy-help">
        <div class="policy-help-item">
          <strong>Allow</strong>
          <span>Explicitly allow federation with this domain, overriding any global restrictions.</span>
        </div>
        <div class="policy-help-item">
          <strong>Silence</strong>
          <span>Posts from this domain won't appear in public timelines or search, but existing followers can still see them.</span>
        </div>
        <div class="policy-help-item">
          <strong>Suspend</strong>
          <span>Completely block all communication. No posts, follows, or messages from this domain.</span>
        </div>
        <div class="policy-help-item">
          <strong>Force NSFW</strong>
          <span>All media from this domain is automatically marked as sensitive and hidden behind a content warning.</span>
        </div>
        <div class="policy-help-item">
          <strong>Block Media</strong>
          <span>Strip all images, videos, and audio from posts. Text content is still federated.</span>
        </div>
      </div>

      <div class="list-items">
        {#each policies as policy (policy.id)}
          <div class="list-item card">
            <div class="list-item-info">
              <strong>{policy.domain}</strong>
              <span class="policy-badge {policyBadgeClass(policy.policy)}">{policy.policy.replace(/_/g, ' ')}</span>
              {#if policy.reason}
                <span class="text-secondary">- {policy.reason}</span>
              {/if}
            </div>
            <div class="list-item-actions">
              {#if policy.policy === 'suspend'}
                <button
                  class="btn btn-sm btn-outline"
                  type="button"
                  onclick={() => openPurgeModal(policy.domain)}
                >Purge Content</button>
              {/if}
              <button
                class="btn btn-sm btn-danger"
                type="button"
                onclick={() => handleDeletePolicy(policy.id)}
              >Remove</button>
            </div>
          </div>
        {:else}
          <p class="empty-text">No federation policies configured</p>
        {/each}
      </div>

    {:else if activeTab === 'delivery'}
      {#if deliveryLoading}
        <div class="delivery-loading">
          <div class="skeleton" style="height: 80px"></div>
          <div class="skeleton" style="height: 120px; margin-top: 16px"></div>
        </div>
      {:else if deliveryStats}
        <!-- Queue snapshot: the four numbers an admin checks first. -->
        <section class="delivery-section">
          <h3 class="delivery-section-title">Queue</h3>
          <div class="delivery-grid">
            <div class="delivery-stat card">
              <div class="delivery-label">Pending</div>
              <div class="delivery-value">{deliveryStats.queue.pending.toLocaleString()}</div>
              <div class="delivery-sub">never attempted</div>
            </div>
            <div class="delivery-stat card">
              <div class="delivery-label">Retrying</div>
              <div class="delivery-value" class:delivery-warn={deliveryStats.queue.retrying > 0}>
                {deliveryStats.queue.retrying.toLocaleString()}
              </div>
              <div class="delivery-sub">failed at least once</div>
            </div>
            <div class="delivery-stat card">
              <div class="delivery-label">Failed (24h)</div>
              <div class="delivery-value" class:delivery-failed={deliveryStats.queue.failed_24h > 0}>
                {deliveryStats.queue.failed_24h.toLocaleString()}
              </div>
              <div class="delivery-sub">exhausted retries</div>
            </div>
            <div class="delivery-stat card">
              <div class="delivery-label">Oldest pending</div>
              <div class="delivery-value">{formatAge(deliveryStats.queue.oldest_pending_age_seconds)}</div>
              <div class="delivery-sub">backlog age</div>
            </div>
          </div>
        </section>

        <!-- Last-hour throughput + per-type breakdown. -->
        <section class="delivery-section">
          <div class="delivery-section-head">
            <h3 class="delivery-section-title">Throughput · last hour</h3>
            <span class="delivery-section-meta">
              {deliveryStats.queue.delivered_24h.toLocaleString()} delivered in last 24h
            </span>
          </div>
          <div class="delivery-throughput card">
            <div class="throughput-chart">
              <Sparkline points={throughputSeries} width={640} height={64} />
            </div>
            {#if typeBreakdown.length > 0}
              <ul class="throughput-types">
                {#each typeBreakdown as t (t.type)}
                  <li class="throughput-type">
                    <span class="throughput-type-label">{t.type}</span>
                    <span class="throughput-type-count">{t.count.toLocaleString()}</span>
                  </li>
                {/each}
              </ul>
            {:else}
              <p class="empty-text">No deliveries in the last hour.</p>
            {/if}
          </div>
        </section>

        <!-- Top failing destinations: where federation is currently broken. -->
        <section class="delivery-section">
          <h3 class="delivery-section-title">Top failing destinations · last 24h</h3>
          {#if deliveryStats.top_failing.length > 0}
            <div class="top-failing">
              {#each deliveryStats.top_failing as row (row.domain)}
                <div class="failing-row card">
                  <div class="failing-head">
                    <span class="failing-domain">{row.domain}</span>
                    <span class="failing-count">{row.failures.toLocaleString()} failures</span>
                  </div>
                  {#if row.last_error}
                    <div class="failing-error" title={row.last_error}>{row.last_error}</div>
                  {/if}
                  <div class="failing-meta">
                    <span>Max attempts: {row.max_attempts}</span>
                    <span>Last: {formatRelative(row.last_attempt_at)}</span>
                  </div>
                </div>
              {/each}
            </div>
          {:else}
            <p class="empty-text">No failing destinations in the last 24h.</p>
          {/if}
        </section>

        <div class="delivery-actions">
          <button class="btn btn-outline" type="button" onclick={loadDelivery}>
            Refresh
          </button>
        </div>
      {/if}

    {:else if activeTab === 'relays'}
      <!-- Lifted from the standalone /admin/relays page so all
           federation surfaces (peers, policies, queue, relays) live
           in one place. The panel manages its own load state. -->
      <RelaysPanel />
    {/if}
  </Tabs>
</div>

<Modal bind:open={purgeModalOpen} title="Purge Instance Content">
  <p class="purge-warning">
    This will permanently remove all cached content from <strong>{purgeDomain}</strong>.
  </p>
  {#if purgePreviewLoading}
    <div class="skeleton" style="height: 60px"></div>
  {:else if purgePreview}
    <div class="purge-stats">
      <div class="purge-stat">
        <span class="purge-stat-label">Users</span>
        <span class="purge-stat-value">{purgePreview.users_count.toLocaleString()}</span>
      </div>
      <div class="purge-stat">
        <span class="purge-stat-label">Posts</span>
        <span class="purge-stat-value">{purgePreview.posts_count.toLocaleString()}</span>
      </div>
      <div class="purge-stat">
        <span class="purge-stat-label">Media files</span>
        <span class="purge-stat-value">{purgePreview.media_count.toLocaleString()}</span>
      </div>
    </div>
  {/if}
  <div class="modal-actions">
    <button class="btn btn-ghost" type="button" onclick={() => (purgeModalOpen = false)}>Cancel</button>
    <button
      class="btn btn-danger"
      type="button"
      disabled={purging || purgePreviewLoading}
      onclick={handlePurge}
    >
      {purging ? 'Purging...' : 'Purge All Content'}
    </button>
  </div>
</Modal>

<style>
  .federation-page {
    max-width: 1100px;
  }

  .policy-help {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: var(--space-4);
    background: var(--color-surface-container-low, #f5f5f5);
    border-radius: var(--radius-lg);
    margin-block-end: var(--space-4);
  }

  .policy-help-item {
    display: flex;
    gap: 8px;
    font-size: 0.8125rem;
    line-height: 1.4;
  }

  .policy-help-item strong {
    flex-shrink: 0;
    min-width: 90px;
    color: var(--color-text);
  }

  .policy-help-item span {
    color: var(--color-text-secondary);
  }

  .page-title {
    font-size: var(--text-2xl);
    font-weight: 700;
    margin-block-end: var(--space-6);
  }

  .instance-status {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    text-transform: capitalize;
  }

  .instance-up {
    background: var(--color-success-soft);
    color: #166534;
  }

  .instance-down {
    background: var(--color-danger-soft);
    color: #991b1b;
  }

  .instance-unknown {
    background: var(--color-surface);
    color: var(--color-text-secondary);
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

  .list-item-actions {
    display: flex;
    gap: var(--space-2);
    flex-shrink: 0;
  }

  .policy-badge {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    text-transform: capitalize;
  }

  .policy-allow {
    background: var(--color-success-soft);
    color: #166534;
  }

  .policy-silence {
    background: var(--color-warning-soft);
    color: #92400e;
  }

  .policy-suspend {
    background: var(--color-danger-soft);
    color: #991b1b;
  }

  .policy-force_nsfw {
    background: var(--color-info-soft);
    color: #1e40af;
  }

  .policy-block_media {
    background: var(--color-surface);
    color: var(--color-text-secondary);
  }

  .delivery-section {
    margin-block-end: var(--space-5);
  }

  .delivery-section-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    margin-block-end: var(--space-2);
  }

  .delivery-section-title {
    font-size: var(--text-sm);
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-text-secondary);
    margin: 0 0 var(--space-2);
  }

  .delivery-section-meta {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .delivery-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: var(--space-3);
  }

  .delivery-stat {
    padding: var(--space-4);
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .delivery-label {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .delivery-value {
    font-size: var(--text-2xl);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
    line-height: 1.1;
  }

  .delivery-sub {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .delivery-ok { color: #16a34a; }
  .delivery-warn { color: #b45309; }
  .delivery-failed { color: var(--color-danger); }

  .delivery-throughput {
    padding: var(--space-4);
    display: flex;
    flex-direction: column;
    /* Comfortable air between the sparkline and the type chips —
       the previous space-3 had a tall spike kissing the chip row.
       Sparkline.svelte uses `overflow: visible` so a near-edge peak
       can render above its nominal box; clipping it would cut off
       data, padding the gap is the right answer. */
    gap: var(--space-5);
    margin-block-start: var(--space-2);
  }

  .throughput-chart {
    width: 100%;
    padding-block: var(--space-2);
  }

  .throughput-types {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    gap: var(--space-3);
    flex-wrap: wrap;
  }

  .throughput-type {
    display: inline-flex;
    align-items: baseline;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 9999px;
    background: var(--color-surface);
    font-size: var(--text-xs);
  }

  .throughput-type-label {
    font-weight: 600;
    color: var(--color-text);
  }

  .throughput-type-count {
    color: var(--color-text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .top-failing {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .failing-row {
    padding: var(--space-3) var(--space-4);
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .failing-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: var(--space-3);
  }

  .failing-domain {
    font-weight: 700;
    font-family: var(--font-mono);
    font-size: var(--text-sm);
  }

  .failing-count {
    font-size: var(--text-xs);
    color: var(--color-danger);
    font-weight: 600;
  }

  .failing-error {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    font-family: var(--font-mono);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .failing-meta {
    display: flex;
    gap: var(--space-3);
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .delivery-actions {
    display: flex;
    gap: var(--space-3);
    margin-block-start: var(--space-3);
  }

  .delivery-loading {
    padding: var(--space-4) 0;
  }

  .purge-warning {
    font-size: var(--text-sm);
    color: var(--color-danger);
    margin-block-end: var(--space-4);
  }

  .purge-stats {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: var(--space-3);
    margin-block-end: var(--space-4);
  }

  .purge-stat {
    text-align: center;
    padding: var(--space-3);
    background: var(--color-surface);
    border-radius: var(--radius-md);
  }

  .purge-stat-label {
    display: block;
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    margin-block-end: var(--space-1);
  }

  .purge-stat-value {
    font-size: var(--text-lg);
    font-weight: 700;
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
    margin-block-start: var(--space-4);
  }

  .empty-text {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    text-align: center;
    padding: var(--space-6) 0;
  }
</style>
