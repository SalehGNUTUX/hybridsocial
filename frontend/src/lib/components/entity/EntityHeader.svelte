<script lang="ts">
  import type { Snippet } from 'svelte';
  import Avatar from '$lib/components/ui/Avatar.svelte';

  // One shared, profile-style header for any "entity" page — Groups and
  // Pages both use it so they share an identical, polished look. The
  // parts that differ per entity (the meta line, primary action, admin
  // controls, extra details, stats) come in as optional snippets.
  let {
    name,
    handle = null,
    avatarUrl = null,
    coverUrl = null,
    description = null,
    meta,
    stats,
    primaryAction,
    adminActions,
  }: {
    name: string;
    handle?: string | null;
    avatarUrl?: string | null;
    coverUrl?: string | null;
    description?: string | null;
    /** Sub-line under the name (e.g. "Public · 1,240 members" or a category). */
    meta?: Snippet;
    /** Stat pills row (followers / members). */
    stats?: Snippet;
    /** The primary CTA (Follow / Join / Leave). */
    primaryAction?: Snippet;
    /** Admin / manage controls (gear, moderation). */
    adminActions?: Snippet;
  } = $props();
</script>

<header class="eh card">
  <div class="eh-cover">
    {#if coverUrl}
      <img src={coverUrl} alt="" class="eh-cover-img" />
    {:else}
      <div class="eh-cover-fallback" aria-hidden="true"></div>
    {/if}
  </div>

  <div class="eh-body">
    <!-- Avatar overlaps the cover on its own row. -->
    <div class="eh-avatar">
      <Avatar src={avatarUrl} {name} size="xl" />
    </div>

    <!-- Title on the left, actions on the right, aligned on the same
         row (clear of the cover). -->
    <div class="eh-headline">
      <div class="eh-identity">
        <h1 class="eh-name">{name}</h1>
        {#if handle}<span class="eh-handle">@{handle}</span>{/if}
      </div>
      {#if adminActions || primaryAction}
        <div class="eh-actions">
          {#if adminActions}{@render adminActions()}{/if}
          {#if primaryAction}{@render primaryAction()}{/if}
        </div>
      {/if}
    </div>

    {#if meta}
      <div class="eh-meta">{@render meta()}</div>
    {/if}

    {#if description}
      <p class="eh-desc">{description}</p>
    {/if}

    {#if stats}
      <div class="eh-stats">{@render stats()}</div>
    {/if}
  </div>
</header>

<style>
  .eh {
    padding: 0;
    /* Let admin popovers escape the card; the cover clips itself. */
    overflow: visible;
  }

  .eh-cover {
    height: 180px;
    overflow: hidden;
    border-start-start-radius: var(--radius-xl);
    border-start-end-radius: var(--radius-xl);
  }

  .eh-cover-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  .eh-cover-fallback {
    width: 100%;
    height: 100%;
    background:
      radial-gradient(circle at 80% -20%, rgba(255, 255, 255, 0.25), transparent 45%),
      var(--gradient-primary);
  }

  .eh-body {
    padding: 0 var(--space-6) var(--space-6);
  }

  /* Avatar overlaps the cover, with a thick surface ring + soft shadow. */
  .eh-avatar {
    margin-block-start: -44px;
    width: fit-content;
  }

  .eh-avatar :global(.avatar) {
    border: 4px solid var(--color-surface-container-lowest);
    box-shadow: var(--shadow-md);
  }

  /* Title + primary/admin actions share a row, aligned at the top so the
     buttons sit level with the name — never pushed up into the cover. */
  .eh-headline {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: var(--space-3);
    flex-wrap: wrap;
    margin-block-start: var(--space-3);
  }

  .eh-actions {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-wrap: wrap;
  }

  .eh-identity {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .eh-name {
    font-size: var(--text-2xl);
    font-weight: 800;
    line-height: 1.2;
    color: var(--color-text);
  }

  .eh-handle {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
  }

  .eh-meta {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: var(--space-2);
    margin-block-start: var(--space-2);
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
  }

  .eh-desc {
    margin-block-start: var(--space-3);
    font-size: var(--text-sm);
    line-height: 1.55;
    color: var(--color-text);
    max-width: 60ch;
  }

  .eh-stats {
    display: flex;
    align-items: center;
    gap: var(--space-5);
    margin-block-start: var(--space-4);
    padding-block-start: var(--space-4);
    border-block-start: 1px solid var(--color-border);
  }

  @media (max-width: 480px) {
    .eh-cover {
      height: 130px;
    }

    .eh-body {
      padding: 0 var(--space-4) var(--space-4);
    }

    .eh-avatar {
      margin-block-start: -40px;
    }
  }
</style>
