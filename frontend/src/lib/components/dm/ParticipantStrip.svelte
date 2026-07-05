<script lang="ts">
  import type { ConversationParticipant } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';

  let {
    participants,
  }: {
    participants: ConversationParticipant[];
  } = $props();

  function nameFor(p: ConversationParticipant): string {
    return p.display_name || p.acct || p.handle || 'Unknown';
  }
</script>

{#if participants.length === 1}
  {@const p = participants[0]}
  <a class="ps-identity" href={`/@${p.handle}`} aria-label={`${nameFor(p)} — view profile`}>
    <Avatar src={p.avatar_url} name={nameFor(p)} size="md" />
    <span class="ps-text">
      <span class="ps-name">{nameFor(p)}</span>
      <span class="ps-handle">@{p.acct || p.handle}</span>
    </span>
  </a>
{:else if participants.length > 1}
  <div class="ps-identity ps-identity-group">
    <span class="ps-avatars" aria-hidden="true">
      {#each participants.slice(0, 3) as p (p.id)}
        <span class="ps-avatar-stacked">
          <Avatar src={p.avatar_url} name={nameFor(p)} size="sm" />
        </span>
      {/each}
    </span>
    <span class="ps-text">
      <span class="ps-name">{participants.map(nameFor).join(', ')}</span>
      <span class="ps-handle">{participants.length} people</span>
    </span>
  </div>
{/if}

<style>
  .ps-identity {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    text-decoration: none;
    color: var(--color-text);
    min-width: 0;
    border-radius: var(--radius-lg);
    transition: opacity var(--transition-fast);
  }

  a.ps-identity:hover {
    text-decoration: none;
    opacity: 0.85;
  }

  .ps-text {
    display: flex;
    flex-direction: column;
    min-width: 0;
    line-height: 1.25;
  }

  .ps-name {
    font-size: var(--text-base);
    font-weight: 700;
    color: var(--color-text);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .ps-handle {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  /* Group DM: overlapping avatar cluster. */
  .ps-avatars {
    display: inline-flex;
    align-items: center;
    flex-shrink: 0;
  }

  .ps-avatar-stacked {
    display: inline-flex;
    border-radius: var(--radius-full);
    box-shadow: 0 0 0 2px var(--color-surface-container-lowest, #fff);
  }

  .ps-avatar-stacked:not(:first-child) {
    margin-inline-start: -12px;
  }
</style>
