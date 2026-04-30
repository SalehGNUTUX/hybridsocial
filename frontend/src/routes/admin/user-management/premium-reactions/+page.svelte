<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client.js';
  import { addToast } from '$lib/stores/toast.js';

  interface PremiumReaction {
    id: string;
    shortcode: string;
    character: string | null;
    image_url: string | null;
    position: number;
    enabled: boolean;
    created_at: string;
  }

  let reactions = $state<PremiumReaction[]>([]);
  let loading = $state(true);
  let saving = $state(false);

  // New entry form
  let newShortcode = $state('');
  let newCharacter = $state('');
  let newImageUrl = $state('');

  const MAX_PREMIUM = 7;

  let canAdd = $derived(reactions.length < MAX_PREMIUM);

  async function load() {
    loading = true;
    try {
      reactions = await api.get<PremiumReaction[]>('/api/v1/admin/premium_reactions');
    } catch {
      addToast('Failed to load premium reactions', 'error');
    } finally {
      loading = false;
    }
  }

  async function create() {
    if (!newShortcode.trim()) return;
    if (!newCharacter.trim() && !newImageUrl.trim()) {
      addToast('Provide either an emoji character or an image URL', 'error');
      return;
    }

    saving = true;
    try {
      const created = await api.post<PremiumReaction>('/api/v1/admin/premium_reactions', {
        shortcode: newShortcode.trim().toLowerCase(),
        character: newCharacter.trim() || null,
        image_url: newImageUrl.trim() || null,
        position: reactions.length,
      });
      reactions = [...reactions, created];
      newShortcode = '';
      newCharacter = '';
      newImageUrl = '';
      addToast('Reaction added', 'success');
    } catch (e: unknown) {
      const err = e as { body?: { error?: string; max?: number } };
      if (err?.body?.error === 'premium_reaction.cap_reached') {
        addToast(`Maximum ${err.body.max} premium reactions reached`, 'error');
      } else {
        addToast('Failed to add reaction', 'error');
      }
    } finally {
      saving = false;
    }
  }

  async function toggleEnabled(reaction: PremiumReaction) {
    try {
      const updated = await api.patch<PremiumReaction>(
        `/api/v1/admin/premium_reactions/${reaction.id}`,
        { enabled: !reaction.enabled },
      );
      reactions = reactions.map((r) => (r.id === reaction.id ? updated : r));
    } catch {
      addToast('Failed to toggle', 'error');
    }
  }

  async function remove(reaction: PremiumReaction) {
    if (
      !confirm(
        `Remove :${reaction.shortcode}: from the premium reaction set? Existing message reactions using it stay; users just can't add it any more.`,
      )
    ) {
      return;
    }

    try {
      await api.delete(`/api/v1/admin/premium_reactions/${reaction.id}`);
      reactions = reactions.filter((r) => r.id !== reaction.id);
      addToast('Reaction removed', 'success');
    } catch {
      addToast('Failed to remove', 'error');
    }
  }

  onMount(load);
</script>

<svelte:head>
  <title>Premium Reactions - Admin</title>
</svelte:head>

<div class="page">
  <header class="page-header">
    <h1>Premium reactions</h1>
    <p class="sub">
      Curate up to {MAX_PREMIUM} extra emoji that premium-tier users
      can react with on posts and messages. Free users see them
      grayed out with an upgrade CTA. Pick conservatively — once
      it's in the catalog, every premium user can reach for it.
    </p>
  </header>

  {#if loading}
    <p class="loading">Loading…</p>
  {:else}
    <section class="catalog">
      <h2>Current catalog ({reactions.length}/{MAX_PREMIUM})</h2>

      {#if reactions.length === 0}
        <p class="empty">No premium reactions configured yet.</p>
      {:else}
        <ul class="reaction-list">
          {#each reactions as r (r.id)}
            <li class="reaction-row" class:disabled={!r.enabled}>
              <span class="reaction-preview">
                {#if r.image_url}
                  <img src={r.image_url} alt="" />
                {:else}
                  {r.character}
                {/if}
              </span>
              <span class="reaction-shortcode">:{r.shortcode}:</span>
              <span class="reaction-spacer"></span>
              <button
                type="button"
                class="btn btn-ghost"
                onclick={() => toggleEnabled(r)}
              >
                {r.enabled ? 'Disable' : 'Enable'}
              </button>
              <button type="button" class="btn btn-ghost-danger" onclick={() => remove(r)}>
                Remove
              </button>
            </li>
          {/each}
        </ul>
      {/if}
    </section>

    <section class="add-form">
      <h2>Add a reaction</h2>
      {#if !canAdd}
        <p class="cap-reached">
          You've reached the {MAX_PREMIUM}-entry cap. Remove one to add a different reaction.
        </p>
      {:else}
        <form onsubmit={(e) => { e.preventDefault(); create(); }}>
          <div class="form-row">
            <label>
              <span>Shortcode</span>
              <input
                type="text"
                bind:value={newShortcode}
                placeholder="e.g. fire"
                pattern="[a-z0-9_]{'{2,32}'}"
                required
              />
              <span class="hint">2-32 chars, lowercase letters/digits/underscores. This is what users select.</span>
            </label>
          </div>

          <div class="form-row two-col">
            <label>
              <span>Emoji character</span>
              <input type="text" bind:value={newCharacter} placeholder="🔥" maxlength="8" />
              <span class="hint">Either this OR an image URL.</span>
            </label>

            <label>
              <span>Image URL</span>
              <input
                type="url"
                bind:value={newImageUrl}
                placeholder="https://…/icon.svg"
              />
              <span class="hint">For custom artwork. Square SVG/PNG works best.</span>
            </label>
          </div>

          <button type="submit" class="btn btn-primary" disabled={saving}>
            {saving ? 'Adding…' : 'Add to catalog'}
          </button>
        </form>
      {/if}
    </section>
  {/if}
</div>

<style>
  .page {
    max-width: 720px;
    padding: var(--space-6);
  }

  .page-header h1 {
    font-size: var(--text-xl);
    margin: 0 0 var(--space-2) 0;
  }

  .sub {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    line-height: 1.5;
    margin: 0 0 var(--space-6) 0;
  }

  .loading,
  .empty {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    padding: var(--space-4);
  }

  .catalog,
  .add-form {
    margin-block-end: var(--space-8);
  }

  .catalog h2,
  .add-form h2 {
    font-size: var(--text-lg);
    margin: 0 0 var(--space-3) 0;
  }

  .reaction-list {
    list-style: none;
    padding: 0;
    margin: 0;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    overflow: hidden;
  }

  .reaction-row {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-3) var(--space-4);
    border-block-end: 1px solid var(--color-border);
  }

  .reaction-row:last-child {
    border-block-end: none;
  }

  .reaction-row.disabled {
    opacity: 0.55;
  }

  .reaction-preview {
    font-size: 1.5rem;
    width: 32px;
    text-align: center;
  }

  .reaction-preview img {
    width: 28px;
    height: 28px;
    vertical-align: middle;
    object-fit: contain;
  }

  .reaction-shortcode {
    font-family: var(--font-mono, ui-monospace, monospace);
    font-weight: 600;
    color: var(--color-text);
  }

  .reaction-spacer {
    flex: 1;
  }

  .form-row {
    margin-block-end: var(--space-4);
  }

  .form-row.two-col {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: var(--space-4);
  }

  .form-row label {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }

  .form-row label > span:first-child {
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-text);
  }

  .form-row input {
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface);
    color: var(--color-text);
    font: inherit;
  }

  .hint {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .cap-reached {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface);
    border-radius: var(--radius-md);
  }
</style>
