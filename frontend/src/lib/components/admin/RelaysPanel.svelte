<script lang="ts">
  import { onMount } from 'svelte';
  import { addToast } from '$lib/stores/toast.js';
  import { getRelays, addRelay, removeRelay } from '$lib/api/admin.js';
  import type { Relay } from '$lib/api/types.js';

  let relays: Relay[] = $state([]);
  let loading = $state(true);
  let newInboxUrl = $state('');
  let adding = $state(false);

  onMount(async () => {
    try {
      relays = await getRelays();
    } catch {
      addToast('Failed to load relays', 'error');
    } finally {
      loading = false;
    }
  });

  async function handleAdd() {
    if (!newInboxUrl.trim()) return;
    adding = true;
    try {
      const relay = await addRelay(newInboxUrl);
      relays = [...relays, relay];
      newInboxUrl = '';
      addToast('Relay added', 'success');
    } catch (e: unknown) {
      const apiErr = e as { body?: { error?: string; message?: string; error_description?: string } };
      if (apiErr?.body?.error === 'relay.already_subscribed') {
        addToast(apiErr.body.message || 'This relay is already in your list.', 'warning');
      } else {
        const msg = apiErr?.body?.message || apiErr?.body?.error_description || 'Failed to add relay';
        addToast(msg, 'error');
      }
    } finally {
      adding = false;
    }
  }

  async function handleRemove(id: string) {
    try {
      await removeRelay(id);
      relays = relays.filter((r) => r.id !== id);
      addToast('Relay removed', 'success');
    } catch {
      addToast('Failed to remove relay', 'error');
    }
  }

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleDateString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric'
    });
  }

  function statusClass(status: string): string {
    switch (status) {
      case 'accepted': return 'status-accepted';
      case 'pending': return 'status-pending';
      case 'rejected': return 'status-rejected';
      case 'failed': return 'status-failed';
      default: return '';
    }
  }
</script>

<div class="relays-panel">
  <p class="panel-desc">Relays are servers that help distribute content across the fediverse.</p>

  <section class="card add-section">
    <h2 class="section-title">Add relay</h2>
    <p class="add-hint">
      Paste the relay URL. Either flavor works — Mastodon-style
      (<code>…/inbox</code>) or Pleroma-style (<code>…/actor</code>).
      We auto-detect which handshake to use.
    </p>
    <form class="add-form" onsubmit={(e) => { e.preventDefault(); handleAdd(); }}>
      <input
        type="url"
        class="input"
        bind:value={newInboxUrl}
        placeholder="https://relay.example.com/inbox  or  https://relay.example.com/actor"
        required
      />
      <button class="btn btn-primary" type="submit" disabled={adding}>
        {adding ? 'Adding...' : 'Add relay'}
      </button>
    </form>
  </section>

  <section class="card">
    <h2 class="section-title">Active relays</h2>

    {#if loading}
      {#each Array(3) as _}
        <div class="skeleton" style="height: 48px; margin-bottom: 8px"></div>
      {/each}
    {:else if relays.length === 0}
      <p class="empty-text">No relays configured</p>
    {:else}
      <div class="relay-list">
        {#each relays as relay (relay.id)}
          <div class="relay-item">
            <div class="relay-info">
              <code class="relay-url">{relay.actor_url || relay.inbox_url}</code>
              <div class="relay-meta">
                <span class="relay-status {statusClass(relay.status)}">{relay.status}</span>
                <span class="relay-style">{relay.style}</span>
                {#if relay.created_at}
                  <span class="relay-date">Added {formatDate(relay.created_at)}</span>
                {/if}
              </div>
              {#if relay.last_error && relay.status === 'failed'}
                <div class="relay-error" role="alert">{relay.last_error}</div>
              {/if}
            </div>
            <button
              class="btn btn-sm btn-danger"
              type="button"
              onclick={() => handleRemove(relay.id)}
            >Remove</button>
          </div>
        {/each}
      </div>
    {/if}
  </section>
</div>

<style>
  .relays-panel {
    max-width: 800px;
  }

  .panel-desc {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    margin-block-end: var(--space-4);
  }

  .section-title {
    font-size: var(--text-lg);
    font-weight: 600;
    margin-block-end: var(--space-3);
  }

  .add-section {
    margin-block-end: var(--space-4);
  }

  .add-form {
    display: flex;
    gap: var(--space-2);
  }

  .add-form .input {
    flex: 1;
  }

  .relay-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .relay-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface);
    border-radius: var(--radius-md);
    gap: var(--space-3);
  }

  .relay-info {
    min-width: 0;
    flex: 1;
  }

  .relay-url {
    font-size: var(--text-sm);
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .relay-meta {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    margin-block-start: var(--space-1);
  }

  .relay-status {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    text-transform: capitalize;
  }

  .status-accepted { background: var(--color-success-soft); color: var(--color-on-success-soft); }
  .status-pending  { background: var(--color-warning-soft); color: var(--color-on-warning-soft); }
  .status-rejected,
  .status-failed   { background: var(--color-danger-soft); color: var(--color-on-danger-soft); }

  .relay-style {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .relay-error {
    margin-block-start: var(--space-2);
    font-size: var(--text-xs);
    color: var(--color-on-danger-soft);
    background: var(--color-danger-soft);
    padding: 6px 10px;
    border-radius: var(--radius-sm);
    font-family: var(--font-mono);
    word-break: break-word;
  }

  .add-hint {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    margin-block-end: var(--space-3);
    line-height: 1.5;
  }

  .relay-date {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .empty-text {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    text-align: center;
    padding: var(--space-6) 0;
  }
</style>
