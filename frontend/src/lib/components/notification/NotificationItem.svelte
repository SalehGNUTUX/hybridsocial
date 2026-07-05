<script lang="ts">
  import type { Notification } from '$lib/api/types.js';
  import { relativeTime } from '$lib/utils/time.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import { premiumCatalog, ensurePremiumCatalog } from '$lib/stores/reaction-catalog.js';

  // Canonical 7 default reactions — must match PostActions/ReactionPicker.
  // Maps the backend `reaction_type` shortcode to the emoji glyph so
  // the notification row can show the actual reaction the actor left
  // instead of a generic thumbs-up icon.
  const REACTION_EMOJI: Record<string, string> = {
    like: '\u{1F44D}',
    love: '\u{2764}\u{FE0F}',
    wow: '\u{1F92F}',
    care: '\u{1F970}',
    angry: '\u{1F621}',
    sad: '\u{1F622}',
    lol: '\u{1F602}',
  };

  // Premium reactions arrive as `:shortcode:` from the backend. Resolve
  // them through the shared catalog the rest of the app uses; without
  // it, premium types render as bare text.
  ensurePremiumCatalog();

  let {
    notification,
    onclick,
  }: {
    notification: Notification;
    onclick?: (notification: Notification) => void;
  } = $props();

  // Resolve the destination URL up front so the wrapping element can
  // be a real <a href>. That preserves the browser's native handling
  // of ctrl/cmd-click (new tab) and shift-click (new window), which a
  // div+goto() can't replicate. SvelteKit's link interceptor still
  // handles the plain-click case as SPA navigation.
  let targetHref = $derived.by(() => {
    switch (notification.type) {
      case 'follow':
      case 'follow_request':
        return `/@${notification.account.handle}`;
      case 'reaction':
      case 'boost':
      case 'favourite':
      case 'mention':
      case 'reply':
      case 'quote':
      case 'update':
      case 'poll':
      case 'poll_ended':
        if (notification.post) return `/post/${notification.post.id}`;
        if (notification.target_id && notification.target_type === 'post') {
          return `/post/${notification.target_id}`;
        }
        return null;
      case 'group_invite':
        if (notification.target_type === 'group' && notification.target_id) {
          return `/groups/${notification.target_id}`;
        }
        return notification.post ? `/groups/${notification.post.id}` : null;
      case 'page_invite':
        if (notification.target_type === 'page' && notification.target_id) {
          return `/pages/${notification.target_id}`;
        }
        return null;
      default:
        return null;
    }
  });

  let timeAgo = $derived(relativeTime(notification.created_at));
  let actorName = $derived(notification.account.display_name || notification.account.handle);

  // For reaction notifications, render the actor's actual emoji
  // (👍/❤️/🤯/🥰/😡/😢/😂 or a premium glyph) instead of the generic
  // SVG icon. Premium reactions can be either a Unicode character or
  // a custom uploaded image, so we surface both an emoji string and
  // an image URL the template picks between.
  type ReactionGlyph =
    | { kind: 'emoji'; emoji: string }
    | { kind: 'image'; url: string; alt: string };

  let reactionGlyph: ReactionGlyph | null = $derived.by(() => {
    if (notification.type !== 'reaction' || !notification.reaction_type) return null;
    const t = notification.reaction_type;
    if (REACTION_EMOJI[t]) return { kind: 'emoji', emoji: REACTION_EMOJI[t] };
    // Premium shortcodes arrive in either `:fire:` or bare `fire` form
    // depending on caller; the catalog is keyed without the colons.
    const key = t.startsWith(':') && t.endsWith(':') ? t.slice(1, -1) : t;
    const glyph = $premiumCatalog.get(key);
    if (glyph?.character) return { kind: 'emoji', emoji: glyph.character };
    if (glyph?.image_url) return { kind: 'image', url: glyph.image_url, alt: key };
    return null;
  });

  let description = $derived.by(() => {
    switch (notification.type) {
      case 'follow':
        return 'followed you';
      case 'follow_request':
        return 'requested to follow you';
      case 'favourite':
        return 'favourited your post';
      case 'reaction':
        return 'reacted to your post';
      case 'boost':
        return 'boosted your post';
      case 'mention':
        return 'mentioned you';
      case 'reply':
        return 'replied to your post';
      case 'quote':
        return 'quoted your post';
      case 'poll':
      case 'poll_ended':
        return 'A poll you voted in has ended';
      case 'update':
        return 'edited a post';
      case 'group_invite':
        return 'invited you to a group';
      case 'group_application':
        return 'applied to join your group';
      case 'page_invite':
        return 'invited you to manage a page';
      case 'report':
        return 'filed a report';
      case 'admin':
        return 'admin action';
      default:
        return 'interacted with you';
    }
  });

  let iconPath = $derived.by(() => {
    switch (notification.type) {
      case 'follow':
      case 'follow_request':
        return 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M14 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0M22 11l-3 3-2-2';
      case 'favourite':
        return 'M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z';
      case 'reaction':
        return 'M14 9V5a3 3 0 0 0-3-3l-4 9v11h11.28a2 2 0 0 0 2-1.7l1.38-9a2 2 0 0 0-2-2.3zM7 22H4a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2h3';
      case 'boost':
        return 'M17 1l4 4-4 4M3 11V9a4 4 0 0 1 4-4h14M7 23l-4-4 4-4M21 13v2a4 4 0 0 1-4 4H3';
      case 'mention':
        return 'M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z';
      case 'reply':
        return 'M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z';
      case 'quote':
        return 'M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M23 11l-3 3-2-2M9 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0z';
      case 'poll':
      case 'poll_ended':
        return 'M18 20V10M12 20V4M6 20v-6';
      default:
        return 'M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9M13.73 21a2 2 0 0 1-3.46 0';
    }
  });

  let iconColor = $derived.by(() => {
    switch (notification.type) {
      case 'follow':
      case 'follow_request':
        return 'var(--color-info)';
      case 'favourite':
        return 'var(--color-danger)';
      case 'reaction':
        return 'var(--color-warning)';
      case 'boost':
        return 'var(--color-success)';
      case 'mention':
      case 'reply':
      case 'quote':
        return 'var(--color-primary)';
      default:
        return 'var(--color-text-secondary)';
    }
  });

  // Mark-read fires on every click — modifier-clicks open elsewhere
  // but the user has still "seen" the notification, so we want the
  // unread highlight to clear regardless. Don't preventDefault: that
  // would break ctrl-click / shift-click / middle-click. SvelteKit's
  // <a> interceptor handles plain SPA nav on its own.
  function handleClick() {
    onclick?.(notification);
  }

  // The inner author link's own click bubbles up here. Without this
  // guard, hitting "@handle" inside the row would trigger the parent
  // mark-read AND navigate to the post — instead of just navigating
  // to the profile.
  function stopBubble(e: MouseEvent | KeyboardEvent) {
    e.stopPropagation();
  }
</script>

{#snippet body()}
  <!-- Single visual anchor: the actor's avatar with a small type badge
       on its corner (reaction rows show the actual reaction glyph). -->
  <div class="notification-avatar-wrap">
    <Avatar src={notification.account.avatar_url} name={actorName} size="md" />
    <span
      class="notification-badge"
      class:notification-badge-glyph={!!reactionGlyph}
      style={reactionGlyph ? '' : `background: ${iconColor}`}
    >
      {#if reactionGlyph?.kind === 'emoji'}
        <span class="reaction-emoji" aria-hidden="true">{reactionGlyph.emoji}</span>
      {:else if reactionGlyph?.kind === 'image'}
        <img class="reaction-image" src={reactionGlyph.url} alt={reactionGlyph.alt} />
      {:else}
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d={iconPath} />
        </svg>
      {/if}
    </span>
  </div>

  <div class="notification-body">
    <p class="notification-text">
      <a href="/@{notification.account.handle}" class="notification-actor-name" onclick={stopBubble}>{actorName}</a>
      {description}
    </p>

    {#if notification.post}
      {@const post = notification.post}
      {@const text = (post.content ?? '').replace(/\s+/g, ' ').trim()}
      {@const snippet = text.length > 30 ? text.slice(0, 30).trimEnd() + '…' : text}
      {@const firstMedia = post.media_attachments?.[0]}
      {@const thumbSrc = firstMedia?.preview_url || firstMedia?.url || null}
      {#if snippet}
        <p class="notification-preview">{snippet}</p>
      {:else if firstMedia && thumbSrc && (firstMedia.type === 'image' || firstMedia.type === 'gifv')}
        <img class="notification-thumb" src={thumbSrc} alt="" />
      {:else if firstMedia && thumbSrc && firstMedia.type === 'video'}
        <span class="notification-thumb notification-thumb-wrap">
          <img src={thumbSrc} alt="" />
          <span class="material-symbols-outlined notification-thumb-icon">play_arrow</span>
        </span>
      {:else if firstMedia}
        <span class="notification-thumb notification-thumb-fallback">
          <span class="material-symbols-outlined notification-thumb-icon">
            {firstMedia.type === 'audio' ? 'graphic_eq' : 'attach_file'}
          </span>
        </span>
      {/if}
    {/if}

    <time class="notification-time" datetime={notification.created_at}>
      {timeAgo}
    </time>
  </div>

  {#if !notification.read}
    <!-- Non-colour-only unread signal: a distinct dot, not just the
         tinted row background (accessibility: don't rely on colour alone). -->
    <span class="notification-unread-dot" role="img" aria-label="Unread"></span>
  {/if}
{/snippet}

{#if targetHref}
  <a
    class="notification-item"
    class:unread={!notification.read}
    href={targetHref}
    onclick={handleClick}
    aria-label="{actorName} {description}"
  >
    {@render body()}
  </a>
{:else}
  <div
    class="notification-item notification-item-static"
    class:unread={!notification.read}
    aria-label="{actorName} {description}"
  >
    {@render body()}
  </div>
{/if}

<style>
  .notification-item {
    display: flex;
    align-items: flex-start;
    gap: var(--space-3);
    padding: var(--space-3) var(--space-4);
    border-radius: var(--radius-lg);
    cursor: pointer;
    transition: background var(--transition-fast);
    /* Kill the ~300ms mobile tap delay so a tap navigates instantly. */
    touch-action: manipulation;
    /* Anchor reset — the row is wrapped in <a> so ctrl/shift-click
       open in new tab/window, but we don't want the default link
       blue / underline on the entire card. */
    color: inherit;
    text-decoration: none;
  }

  .notification-item:hover {
    text-decoration: none;
  }

  .notification-item-static {
    cursor: default;
  }

  .notification-item:hover {
    background: var(--color-surface);
  }

  .notification-item:focus-visible {
    outline: 2px solid var(--color-primary);
    outline-offset: -2px;
  }

  .notification-item.unread {
    background: var(--color-primary-soft);
  }

  .notification-item.unread:hover {
    background: color-mix(in srgb, var(--color-primary-soft) 80%, var(--color-surface) 20%);
  }

  /* Avatar + corner type badge — one visual anchor per row. */
  .notification-avatar-wrap {
    position: relative;
    flex-shrink: 0;
  }

  .notification-badge {
    position: absolute;
    inset-inline-end: -3px;
    inset-block-end: -3px;
    width: 20px;
    height: 20px;
    border-radius: var(--radius-full);
    display: flex;
    align-items: center;
    justify-content: center;
    color: #fff;
    /* Ring in the row surface colour lifts the badge off the avatar. */
    box-shadow: 0 0 0 2px var(--color-surface-container-lowest, #fff);
    box-sizing: border-box;
  }

  /* Reaction rows show the actual glyph on a light chip instead of a
     coloured icon badge. */
  .notification-badge-glyph {
    background: var(--color-surface-container-lowest, #fff);
  }

  .reaction-emoji {
    font-size: 13px;
    line-height: 1;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }

  .reaction-image {
    width: 14px;
    height: 14px;
    object-fit: contain;
  }

  .notification-body {
    flex: 1;
    min-width: 0;
    padding-block-start: 2px;
  }

  .notification-unread-dot {
    flex-shrink: 0;
    align-self: center;
    width: 9px;
    height: 9px;
    border-radius: var(--radius-full);
    background: var(--color-primary);
    margin-inline-start: var(--space-1);
  }

  .notification-text {
    font-size: var(--text-sm);
    color: var(--color-text);
    line-height: 1.4;
  }

  .notification-actor-name {
    font-weight: 600;
    color: var(--color-text);
    text-decoration: none;
  }

  .notification-actor-name:hover {
    text-decoration: underline;
  }

  .notification-preview {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    margin-block-start: var(--space-1);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .notification-thumb {
    display: inline-block;
    margin-block-start: var(--space-1);
    width: 40px;
    height: 40px;
    border-radius: var(--radius-sm);
    object-fit: cover;
    background: var(--color-surface-container, var(--color-surface));
    overflow: hidden;
  }

  .notification-thumb-wrap {
    position: relative;
  }

  .notification-thumb-wrap img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }

  .notification-thumb-icon {
    position: absolute;
    inset: 0;
    margin: auto;
    color: white;
    font-size: 18px;
    text-shadow: 0 0 6px rgba(0, 0, 0, 0.6);
    width: 18px;
    height: 18px;
    line-height: 1;
  }

  .notification-thumb-fallback {
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }

  .notification-thumb-fallback .notification-thumb-icon {
    position: static;
    color: var(--color-text-secondary);
    text-shadow: none;
  }

  .notification-time {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
    margin-block-start: var(--space-1);
    display: block;
  }
</style>
