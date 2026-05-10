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

{#if participants.length > 0}
  <ul class="strip" aria-label="Conversation participants">
    {#each participants as p (p.id)}
      <li>
        <a class="chip" href={`/@${p.handle}`} title={nameFor(p)}>
          <Avatar src={p.avatar_url} name={nameFor(p)} size="md" />
          <span class="chip-name">{nameFor(p)}</span>
        </a>
      </li>
    {/each}
  </ul>
{/if}

<style>
  .strip {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: row;
    align-items: flex-start;
    gap: var(--space-3, 12px);
    overflow-x: auto;
    overflow-y: hidden;
    /* Quietly hide the horizontal scrollbar — bar is distracting on
       1-on-1 chats where it'd be there but never used. Touch and
       trackpad still scroll naturally. */
    scrollbar-width: none;
    -ms-overflow-style: none;
    padding-block: 4px;
    /* Bleed slightly past the flex container's gap so chips don't
       look glued to the edges when the strip overflows. */
    scroll-padding-inline: 8px;
  }

  .strip::-webkit-scrollbar {
    display: none;
  }

  .strip > li {
    flex: 0 0 auto;
    list-style: none;
  }

  .chip {
    flex: 0 0 auto;
    display: inline-flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
    text-decoration: none;
    color: var(--color-text);
    max-width: 88px;
    transition: transform var(--transition-fast);
  }

  .chip:hover {
    text-decoration: none;
    transform: translateY(-2px);
  }

  .chip:hover .chip-name {
    color: var(--color-primary, #3b82f6);
  }

  .chip-name {
    font-size: var(--text-xs, 0.75rem);
    font-weight: 600;
    color: var(--color-text);
    text-align: center;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 100%;
    transition: color var(--transition-fast);
  }
</style>
