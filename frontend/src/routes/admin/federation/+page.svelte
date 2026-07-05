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
    latency: {
      domain: string;
      samples: number;
      p50_ms: number | null;
      p95_ms: number | null;
      max_ms: number | null;
    }[];
  };
  let deliveryStats: FederationDelivery | null = $state(null);
  let deliveryLoading = $state(false);

  // Dead-letter queue: rows with status=failed. The Delivery Queue tab
  // grows a section below the throughput/failures cards listing them
  // with per-row Retry / Drop buttons and a per-domain Retry-all
  // bulk action.
  type DeadLetter = {
    id: string;
    activity_id: string;
    activity_type: string | null;
    actor_id: string | null;
    target_inbox: string;
    domain: string | null;
    attempts: number;
    last_attempt_at: string | null;
    inserted_at: string;
    error: string | null;
    body_available: boolean;
  };
  let deadLetters: DeadLetter[] = $state([]);
  let deadLettersTotal = $state(0);
  let deadLettersLoading = $state(false);
  let deadLettersBusy = $state<string | null>(null);

  async function loadDeadLetters() {
    deadLettersLoading = true;
    try {
      const res = await api.get<{ data: DeadLetter[]; total: number }>(
        '/api/v1/admin/federation/dead_letters',
        { limit: '50' },
      );
      deadLetters = res.data || [];
      deadLettersTotal = res.total || 0;
    } catch {
      addToast('Failed to load dead-letter queue', 'error');
    } finally {
      deadLettersLoading = false;
    }
  }

  async function retryDeadLetter(item: DeadLetter) {
    if (deadLettersBusy) return;
    deadLettersBusy = item.id;
    try {
      const res = await api.post<{ status: string }>(
        `/api/v1/admin/federation/dead_letters/${item.id}/retry`,
      );
      if (res.status === 'delivered') {
        addToast('Delivered', 'success');
        deadLetters = deadLetters.filter((d) => d.id !== item.id);
        deadLettersTotal = Math.max(0, deadLettersTotal - 1);
      } else {
        addToast('Retry failed — error updated on the row', 'warning');
        await loadDeadLetters();
      }
      await loadDelivery();
    } catch (e) {
      const apiErr = e as { body?: { error?: string } };
      const code = apiErr?.body?.error;
      if (code === 'dead_letter.body_not_available') {
        addToast('Cannot retry — activity body was not stored on this row', 'error');
      } else if (code === 'dead_letter.actor_not_found') {
        addToast('Cannot retry — original actor no longer exists', 'error');
      } else {
        addToast('Retry failed', 'error');
      }
    } finally {
      deadLettersBusy = null;
    }
  }

  async function dropDeadLetter(item: DeadLetter) {
    if (deadLettersBusy) return;
    if (!confirm(`Permanently drop this delivery to ${item.domain ?? item.target_inbox}? This can't be undone.`)) return;
    deadLettersBusy = item.id;
    try {
      await api.delete(`/api/v1/admin/federation/dead_letters/${item.id}`);
      deadLetters = deadLetters.filter((d) => d.id !== item.id);
      deadLettersTotal = Math.max(0, deadLettersTotal - 1);
      addToast('Dropped', 'success');
      await loadDelivery();
    } catch {
      addToast('Failed to drop', 'error');
    } finally {
      deadLettersBusy = null;
    }
  }

  async function retryAllForDomain(domain: string) {
    if (deadLettersBusy) return;
    if (!confirm(`Retry every failed delivery for ${domain}?`)) return;
    deadLettersBusy = `domain:${domain}`;
    try {
      const res = await api.post<{ delivered: number; failed: number }>(
        '/api/v1/admin/federation/dead_letters/retry_domain',
        { domain },
      );
      addToast(
        `${domain}: ${res.delivered} delivered · ${res.failed} still failing`,
        res.failed === 0 ? 'success' : 'warning',
      );
      await loadDeadLetters();
      await loadDelivery();
    } catch {
      addToast('Bulk retry failed', 'error');
    } finally {
      deadLettersBusy = null;
    }
  }

  // Group dead letters by domain so the per-domain bulk action button
  // surfaces naturally next to its rows.
  let deadLettersByDomain = $derived.by(() => {
    const groups: Record<string, DeadLetter[]> = {};
    for (const dl of deadLetters) {
      const key = dl.domain ?? 'unknown';
      if (!groups[key]) groups[key] = [];
      groups[key].push(dl);
    }
    return Object.entries(groups)
      .map(([domain, items]) => ({ domain, items }))
      .sort((a, b) => b.items.length - a.items.length);
  });

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
      loadDeadLetters();
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

  async function handleDeletePolicy(domain: string) {
    try {
      await deleteFederationPolicy(domain);
      policies = policies.filter((p) => p.domain !== domain);
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
        {#each policies as policy (policy.domain)}
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
                onclick={() => handleDeletePolicy(policy.domain)}
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

        <!-- Per-peer delivery latency: p50/p95 ms over the last hour
             for the top destinations by sample count. Spots a slow
             peer dragging the queue without needing per-row data. -->
        <section class="delivery-section">
          <h3 class="delivery-section-title">Per-peer latency · last hour</h3>
          {#if deliveryStats.latency.length === 0}
            <p class="empty-text">Not enough delivered samples in the last hour to compute percentiles.</p>
          {:else}
            <div class="latency-grid card">
              <div class="latency-row latency-head">
                <span>Domain</span>
                <span class="latency-num">p50</span>
                <span class="latency-num">p95</span>
                <span class="latency-num">max</span>
                <span class="latency-num">samples</span>
              </div>
              {#each deliveryStats.latency as l (l.domain)}
                <div class="latency-row">
                  <span class="latency-domain">{l.domain}</span>
                  <span class="latency-num">{l.p50_ms ?? '—'} ms</span>
                  <span class="latency-num" class:latency-warn={(l.p95_ms ?? 0) > 1000} class:latency-bad={(l.p95_ms ?? 0) > 5000}>{l.p95_ms ?? '—'} ms</span>
                  <span class="latency-num">{l.max_ms ?? '—'} ms</span>
                  <span class="latency-num">{l.samples.toLocaleString()}</span>
                </div>
              {/each}
            </div>
          {/if}
        </section>

        <!-- Dead-letter queue: deliveries that exhausted their retries.
             Lists them grouped by domain so the per-domain bulk
             retry sits next to its rows; per-row retry/drop fall
             back if the body wasn't stored (pre-feature rows). -->
        <section class="delivery-section">
          <div class="delivery-section-head">
            <h3 class="delivery-section-title">Dead-letter queue</h3>
            <span class="delivery-section-meta">
              {deadLettersTotal.toLocaleString()} total
            </span>
          </div>
          {#if deadLettersLoading}
            <div class="skeleton" style="height: 96px"></div>
          {:else if deadLetters.length === 0}
            <p class="empty-text">No dead letters. Federation is clean.</p>
          {:else}
            <div class="dead-letter-groups">
              {#each deadLettersByDomain as group (group.domain)}
                <div class="dead-letter-group card">
                  <header class="dl-group-head">
                    <span class="failing-domain">{group.domain}</span>
                    <span class="dl-group-meta">
                      {group.items.length} failed
                    </span>
                    {#if group.items.length > 1}
                      <button
                        type="button"
                        class="btn btn-sm btn-outline"
                        onclick={() => retryAllForDomain(group.domain)}
                        disabled={deadLettersBusy === `domain:${group.domain}`}
                      >
                        {deadLettersBusy === `domain:${group.domain}` ? 'Retrying…' : 'Retry all'}
                      </button>
                    {/if}
                  </header>
                  <ul class="dl-list">
                    {#each group.items as item (item.id)}
                      <li class="dl-row">
                        <div class="dl-row-main">
                          <span class="dl-type">{item.activity_type ?? 'Activity'}</span>
                          <span class="dl-attempts">{item.attempts} attempt{item.attempts === 1 ? '' : 's'}</span>
                          <span class="dl-when">{formatRelative(item.last_attempt_at)}</span>
                        </div>
                        {#if item.error}
                          <div class="dl-error" title={item.error}>{item.error}</div>
                        {/if}
                        <div class="dl-row-actions">
                          <button
                            type="button"
                            class="btn btn-sm btn-primary"
                            onclick={() => retryDeadLetter(item)}
                            disabled={!item.body_available || deadLettersBusy === item.id}
                            title={item.body_available ? '' : 'Body not stored on this row'}
                          >
                            {deadLettersBusy === item.id ? 'Retrying…' : 'Retry'}
                          </button>
                          <button
                            type="button"
                            class="btn btn-sm btn-danger"
                            onclick={() => dropDeadLetter(item)}
                            disabled={deadLettersBusy === item.id}
                          >
                            Drop
                          </button>
                        </div>
                      </li>
                    {/each}
                  </ul>
                </div>
              {/each}
            </div>
          {/if}
        </section>

        <div class="delivery-actions">
          <button class="btn btn-outline" type="button" onclick={() => { loadDelivery(); loadDeadLetters(); }}>
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

  /* Per-peer latency table — five columns, monospace numbers so the
     three timing columns line up regardless of magnitude. */
  .latency-grid {
    padding: var(--space-2) var(--space-4);
    display: flex;
    flex-direction: column;
  }

  .latency-row {
    display: grid;
    grid-template-columns: 1.5fr repeat(4, 1fr);
    gap: var(--space-3);
    align-items: center;
    padding: 8px 0;
    font-size: var(--text-sm);
  }

  .latency-row + .latency-row {
    border-block-start: 1px solid var(--color-border);
  }

  .latency-head {
    font-size: var(--text-xs);
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--color-text-tertiary);
  }

  .latency-domain {
    font-family: var(--font-mono);
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .latency-num {
    text-align: end;
    font-variant-numeric: tabular-nums;
    color: var(--color-text-secondary);
  }

  .latency-warn { color: #b45309; font-weight: 600; }
  .latency-bad { color: var(--color-danger); font-weight: 700; }

  .dead-letter-groups {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .dead-letter-group {
    padding: var(--space-3) var(--space-4);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .dl-group-head {
    display: flex;
    align-items: center;
    gap: var(--space-3);
  }

  .dl-group-meta {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    flex: 1;
  }

  .dl-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    border-block-start: 1px solid var(--color-border);
    padding-block-start: var(--space-2);
  }

  .dl-row {
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 4px var(--space-3);
    align-items: center;
  }

  .dl-row-main {
    display: flex;
    align-items: baseline;
    gap: var(--space-3);
    font-size: var(--text-sm);
  }

  .dl-type {
    font-weight: 600;
  }

  .dl-attempts,
  .dl-when {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .dl-error {
    grid-column: 1;
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    font-family: var(--font-mono);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .dl-row-actions {
    grid-column: 2;
    grid-row: 1 / span 2;
    display: flex;
    gap: 6px;
    flex-shrink: 0;
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
