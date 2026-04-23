<script lang="ts">
  import type { Message } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import MessageReactionPicker from '$lib/components/dm/MessageReactionPicker.svelte';
  import { loadReactionCatalog, resolveReaction } from '$lib/utils/message-reactions.js';
  import { onMount } from 'svelte';
  import { fly, scale } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';

  let {
    message,
    isOwn = false,
    showAvatar = true,
    ondelete,
    onreact,
    onedit,
  }: {
    message: Message;
    isOwn?: boolean;
    showAvatar?: boolean;
    ondelete?: (messageId: string) => void;
    onreact?: (messageId: string, emoji: string) => void;
    onedit?: (messageId: string, newContent: string) => Promise<void>;
  } = $props();

  // Server enforces a 5-minute edit window — mirror it client-side
  // so the Edit button only shows while it's actually usable. Tick
  // every 30 seconds so the button auto-disappears at the cutoff
  // without needing a page refresh.
  const EDIT_WINDOW_MS = 5 * 60 * 1000;
  let nowTick = $state(Date.now());
  $effect(() => {
    if (!isOwn || !onedit) return;
    const interval = setInterval(() => {
      nowTick = Date.now();
    }, 30_000);
    return () => clearInterval(interval);
  });
  let canEdit = $derived.by(() => {
    if (!isOwn || !onedit) return false;
    const created = new Date(message.created_at).getTime();
    return nowTick - created < EDIT_WINDOW_MS;
  });

  let formattedTime = $derived(
    new Date(message.created_at).toLocaleTimeString(undefined, {
      hour: 'numeric',
      minute: '2-digit'
    })
  );

  let isRead = $derived(!!message.read_at);
  let isPending = $derived(!!message.pending);
  let mediaAttachments = $derived(message.media_attachments || []);
  let reactions = $derived(message.reactions || []);
  let sender = $derived(message.sender || {});

  let pickerOpen = $state(false);
  let confirmingDelete = $state(false);
  let editing = $state(false);
  let editDraft = $state('');
  let savingEdit = $state(false);

  // Debounce timers for the hover-open picker. Open after a short
  // intent delay so a quick scroll-past doesn't pop the picker; close
  // a bit slower so users have time to move into the picker without
  // it dismissing from under them.
  const OPEN_DELAY = 150;
  const CLOSE_DELAY = 250;
  let openTimer: ReturnType<typeof setTimeout> | null = null;
  let closeTimer: ReturnType<typeof setTimeout> | null = null;

  function clearTimers() {
    if (openTimer) {
      clearTimeout(openTimer);
      openTimer = null;
    }
    if (closeTimer) {
      clearTimeout(closeTimer);
      closeTimer = null;
    }
  }

  function schedulePickerOpen() {
    clearTimers();
    openTimer = setTimeout(() => {
      pickerOpen = true;
      openTimer = null;
    }, OPEN_DELAY);
  }

  function schedulePickerClose() {
    clearTimers();
    closeTimer = setTimeout(() => {
      pickerOpen = false;
      closeTimer = null;
    }, CLOSE_DELAY);
  }

  function togglePickerClick(e: MouseEvent) {
    e.stopPropagation();
    clearTimers();
    pickerOpen = !pickerOpen;
  }

  // The reaction catalog is loaded once and cached at module level;
  // we just need a re-render trigger after the fetch resolves so the
  // {#each} below re-runs `resolveReaction` for any premium codes.
  let catalogReady = $state(false);
  onMount(() => {
    loadReactionCatalog()
      .then(() => (catalogReady = true))
      .catch(() => (catalogReady = true));

    return () => clearTimers();
  });

  let resolvedReactions = $derived.by(() => {
    void catalogReady;
    return reactions.map((r) => ({ ...r, display: resolveReaction(r.emoji) }));
  });

  function handleReact(emoji: string) {
    pickerOpen = false;
    onreact?.(message.id, emoji);
  }

  function requestDelete(e: MouseEvent) {
    e.stopPropagation();
    confirmingDelete = true;
  }

  function confirmDelete() {
    confirmingDelete = false;
    ondelete?.(message.id);
  }

  function cancelDelete() {
    confirmingDelete = false;
  }

  function startEdit(e: MouseEvent) {
    e.stopPropagation();
    editDraft = message.content || '';
    editing = true;
  }

  function cancelEdit() {
    editing = false;
    editDraft = '';
  }

  async function saveEdit() {
    if (!onedit || savingEdit) return;
    const trimmed = editDraft.trim();
    if (trimmed === '' || trimmed === message.content) {
      cancelEdit();
      return;
    }
    savingEdit = true;
    try {
      await onedit(message.id, trimmed);
      editing = false;
    } finally {
      savingEdit = false;
    }
  }

  function handleEditKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      cancelEdit();
    } else if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      saveEdit();
    }
  }
</script>

<div
  class="message-row"
  class:own={isOwn}
  class:pending={isPending}
  in:fly={{ y: 24, duration: 280, easing: cubicOut }}
>
  {#if !isOwn && showAvatar}
    <div class="message-avatar">
      <Avatar
        src={sender.avatar_url}
        name={sender.display_name || sender.handle || '?'}
        size="sm"
      />
    </div>
  {:else if !isOwn}
    <div class="avatar-spacer"></div>
  {/if}

  <div class="bubble-wrapper" class:wrapper-own={isOwn}>
    <div class="bubble" class:bubble-own={isOwn} class:bubble-other={!isOwn}>
      {#if editing}
        <div
          class="edit-shell"
          transition:scale={{ start: 0.95, duration: 150, easing: cubicOut }}
        >
          <textarea
            class="edit-textarea"
            bind:value={editDraft}
            onkeydown={handleEditKeydown}
            disabled={savingEdit}
            rows="2"
            aria-label="Edit message"
            autofocus
          ></textarea>
          <div class="edit-actions">
            <button
              type="button"
              class="btn-mini"
              onclick={cancelEdit}
              disabled={savingEdit}
            >
              Cancel
            </button>
            <button
              type="button"
              class="btn-mini btn-mini-primary"
              onclick={saveEdit}
              disabled={savingEdit || editDraft.trim() === ''}
            >
              {savingEdit ? 'Saving…' : 'Save'}
            </button>
          </div>
          <span class="edit-hint">Enter to save, Esc to cancel.</span>
        </div>
      {:else if message.content_html}
        <div class="message-body" dir="auto">
          {@html message.content_html}
        </div>
      {:else}
        <p class="message-text" dir="auto">{message.content}</p>
      {/if}

      {#if mediaAttachments.length > 0}
        <div class="message-media">
          {#each mediaAttachments as attachment (attachment.id)}
            {#if attachment.type === 'image'}
              <img
                src={attachment.preview_url || attachment.url}
                alt={attachment.description || 'Attached image'}
                class="media-image"
                loading="lazy"
              />
            {:else if attachment.type === 'video'}
              <video src={attachment.url} controls preload="metadata" class="media-video">
                <track kind="captions" />
              </video>
            {/if}
          {/each}
        </div>
      {/if}

      <div class="message-meta">
        <time class="message-time" datetime={message.created_at}>{formattedTime}</time>
        {#if message.edited_at}
          <span class="message-edited">edited</span>
        {/if}
        {#if isPending}
          <span class="message-pending">sending...</span>
        {:else if isOwn}
          <span class="read-receipt" class:read={isRead} aria-label={isRead ? 'Read' : 'Sent'}>
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              {#if isRead}
                <polyline points="1 12 5 16 12 9" />
                <polyline points="7 12 11 16 18 9" />
              {:else}
                <polyline points="4 12 8 16 16 8" />
              {/if}
            </svg>
          </span>
        {/if}
      </div>

      {#if resolvedReactions.length > 0}
        <div class="reactions-overlay" class:overlay-own={isOwn}>
          {#each resolvedReactions as r (r.emoji)}
            <span
              class="msg-reaction"
              title="{r.count} × :{r.emoji}:"
              transition:scale={{ start: 0.6, duration: 200, easing: cubicOut }}
            >
              {#if r.display.kind === 'image'}
                <img class="msg-reaction-img" src={r.display.src} alt="" />
              {:else if r.display.kind === 'char'}
                <span class="msg-reaction-char">{r.display.value}</span>
              {:else}
                <span class="msg-reaction-fallback">:{r.display.value}:</span>
              {/if}
              {#if r.count > 1}<span class="msg-reaction-count">{r.count}</span>{/if}
            </span>
          {/each}
        </div>
      {/if}
    </div>

    {#if !isPending && !editing}
      <div class="bubble-actions">
        <!-- Hover-zone wraps the smiley button + the picker so moving
             between them doesn't trigger a close. -->
        <div
          class="reaction-hover-zone"
          onmouseenter={schedulePickerOpen}
          onmouseleave={schedulePickerClose}
          role="presentation"
        >
          <button
            type="button"
            class="bubble-action-btn"
            title="Add reaction"
            aria-label="Add reaction"
            aria-expanded={pickerOpen}
            onclick={togglePickerClick}
          >
            <span class="material-symbols-outlined">add_reaction</span>
          </button>

          {#if pickerOpen}
            <div
              class="picker-anchor"
              class:picker-anchor-own={isOwn}
              transition:fly={{ y: -6, duration: 180, easing: cubicOut }}
            >
              <MessageReactionPicker
                onpick={handleReact}
                onclose={() => (pickerOpen = false)}
              />
            </div>
          {/if}
        </div>

        {#if canEdit}
          <button
            type="button"
            class="bubble-action-btn"
            title="Edit message (5 min window)"
            aria-label="Edit message"
            onclick={startEdit}
          >
            <span class="material-symbols-outlined">edit</span>
          </button>
        {/if}

        {#if isOwn && ondelete}
          <button
            type="button"
            class="bubble-action-btn bubble-action-danger"
            title="Delete message"
            aria-label="Delete message"
            onclick={requestDelete}
          >
            <span class="material-symbols-outlined">delete</span>
          </button>
        {/if}
      </div>

      {#if confirmingDelete}
        <div
          class="delete-confirm"
          role="alertdialog"
          aria-live="polite"
          transition:fly={{ y: -6, duration: 180, easing: cubicOut }}
        >
          <span class="delete-confirm-text">Delete this message?</span>
          <div class="delete-confirm-actions">
            <button type="button" class="btn-mini" onclick={cancelDelete}>Cancel</button>
            <button type="button" class="btn-mini btn-mini-danger" onclick={confirmDelete}>
              Delete
            </button>
          </div>
        </div>
      {/if}
    {/if}
  </div>
</div>

<style>
  .message-row {
    display: flex;
    align-items: flex-end;
    gap: var(--space-2);
    /* Extra block-end so the half-outside reaction chips don't visually
       collide with the next bubble underneath. */
    margin-block-end: 14px;
  }

  /* When a new message arrives the page sets `.rippling` on the
     scroll container; each row runs a tiny upward bounce, staggered
     from the bottom up via the `--ripple-i` index that the page
     writes inline. The newest row (index 0) pushes first; each one
     above is a frame later, so it reads as a wave moving up the
     stack. */
  :global(.messages-container.rippling) .message-row {
    animation: bubble-ripple 0.55s ease-out;
    animation-delay: calc(var(--ripple-i, 0) * 28ms);
    will-change: transform;
  }

  @keyframes bubble-ripple {
    0% {
      transform: translateY(0);
    }
    35% {
      transform: translateY(-4px);
    }
    65% {
      transform: translateY(1px);
    }
    100% {
      transform: translateY(0);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    :global(.messages-container.rippling) .message-row {
      animation: none;
    }
  }

  .message-row.own {
    flex-direction: row-reverse;
  }

  .message-avatar {
    flex-shrink: 0;
  }

  .avatar-spacer {
    width: 28px;
    flex-shrink: 0;
  }

  .bubble-wrapper {
    position: relative;
    display: flex;
    align-items: flex-end;
    gap: 4px;
    max-width: 75%;
  }

  .wrapper-own {
    margin-inline-start: auto;
    flex-direction: row-reverse;
  }

  .bubble {
    position: relative;
    padding: var(--space-2) var(--space-3);
    word-break: break-word;
  }

  .bubble-own {
    background: var(--color-primary-soft);
    border-radius: var(--radius-lg) var(--radius-lg) var(--radius-xs) var(--radius-lg);
  }

  .bubble-other {
    background: var(--color-surface);
    border-radius: var(--radius-lg) var(--radius-lg) var(--radius-lg) var(--radius-xs);
  }

  .bubble-actions {
    display: flex;
    align-items: center;
    gap: 2px;
    opacity: 0;
    /* Slide in slightly from the bubble side as we fade — feels
       intentional rather than just appearing. Direction is set per
       wrapper below so the slide always comes FROM the bubble. */
    transform: translateX(-4px);
    transition:
      opacity var(--transition-fast),
      transform var(--transition-fast);
    flex-shrink: 0;
  }

  .wrapper-own .bubble-actions {
    transform: translateX(4px);
  }

  .bubble-wrapper:hover .bubble-actions,
  .bubble-wrapper:focus-within .bubble-actions {
    opacity: 1;
    transform: translateX(0);
  }

  .bubble-action-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    background: var(--color-surface-raised, var(--color-surface));
    border: 1px solid var(--color-border);
    border-radius: 50%;
    cursor: pointer;
    color: var(--color-text-secondary);
    transition:
      background-color var(--transition-fast),
      color var(--transition-fast),
      border-color var(--transition-fast),
      transform var(--transition-fast);
  }

  .bubble-action-btn:hover {
    background: var(--color-surface);
    color: var(--color-text);
    border-color: var(--color-text-tertiary);
    transform: scale(1.08);
  }

  .bubble-action-btn .material-symbols-outlined {
    font-size: 16px !important;
  }

  .bubble-action-danger:hover {
    color: var(--color-danger, #b00);
    border-color: var(--color-danger, #b00);
  }

  /* Touch devices have no hover — show actions inline so users can tap them. */
  @media (hover: none) {
    .bubble-actions {
      opacity: 1;
    }
  }

  .reaction-hover-zone {
    position: relative;
    display: inline-flex;
  }

  /* Each .message-row creates its own stacking context via the ripple
     animation's will-change (and later rows paint on top in DOM order),
     so a local z-index on .picker-anchor can't escape upward — later
     bubbles would cover the picker. Promote the host row while the
     picker is open so it paints above its siblings. */
  :global(.message-row:has(.picker-anchor)) {
    position: relative;
    z-index: 50;
  }

  .picker-anchor {
    position: absolute;
    inset-block-start: 100%;
    inset-inline-end: 0;
    z-index: var(--z-dropdown, 100);
    margin-block-start: 4px;
  }

  /* Own messages put the reaction button on the LEFT side of the
     bubble (row-reverse). Anchoring the picker to inline-end would
     pop it further left into the sidebar, so flip to inline-start
     so it opens rightward, staying inside the chat area. */
  .picker-anchor-own {
    inset-inline-end: auto;
    inset-inline-start: 0;
  }

  .delete-confirm {
    position: absolute;
    inset-block-start: 100%;
    inset-inline-end: 0;
    z-index: var(--z-dropdown, 100);
    margin-block-start: 4px;
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-2) var(--space-3);
    background: var(--color-surface-raised, var(--color-surface));
    border: 1px solid var(--color-danger, #b00);
    border-radius: var(--radius-md, 8px);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
    white-space: nowrap;
  }

  .delete-confirm-text {
    font-size: var(--text-sm);
    color: var(--color-text);
  }

  .delete-confirm-actions {
    display: flex;
    gap: 4px;
  }

  .btn-mini {
    padding: 4px 10px;
    border: none;
    background: transparent;
    border-radius: 6px;
    font-size: var(--text-xs);
    font-weight: 600;
    cursor: pointer;
    color: var(--color-text-secondary);
  }

  .btn-mini:hover {
    background: var(--color-surface);
    color: var(--color-text);
  }

  .btn-mini-danger {
    background: var(--color-danger, #b00);
    color: white;
  }

  .btn-mini-danger:hover {
    background: var(--color-danger, #900);
    color: white;
  }

  .btn-mini-primary {
    background: var(--color-primary, #3b82f6);
    color: white;
  }

  .btn-mini-primary:hover {
    background: var(--color-primary-hover, #2563eb);
    color: white;
  }

  /* Inline edit shell */
  .edit-shell {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 180px;
  }

  .edit-textarea {
    width: 100%;
    padding: 6px 8px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm, 4px);
    background: var(--color-surface, white);
    color: var(--color-text);
    font: inherit;
    font-size: var(--text-sm);
    resize: vertical;
    min-height: 56px;
  }

  .edit-actions {
    display: flex;
    justify-content: flex-end;
    gap: 4px;
  }

  .edit-hint {
    font-size: 10px;
    color: var(--color-text-tertiary);
    text-align: end;
  }

  .message-text {
    font-size: var(--text-sm);
    line-height: 1.5;
    color: var(--color-text);
    unicode-bidi: plaintext;
  }

  .message-body {
    font-size: var(--text-sm);
    line-height: 1.5;
    color: var(--color-text);
  }

  /* Per-paragraph direction inside message bodies — pairs with
     `dir="auto"` on the wrapper so Arabic/English/Hebrew mixed in
     one message each flip correctly. */
  .message-body :global(p),
  .message-body :global(li),
  .message-body :global(blockquote) {
    unicode-bidi: plaintext;
  }

  .message-media {
    margin-block-start: var(--space-2);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .media-image {
    border-radius: var(--radius-md);
    max-width: 100%;
    max-height: 300px;
    object-fit: cover;
  }

  .media-video {
    border-radius: var(--radius-md);
    max-width: 100%;
    max-height: 300px;
  }

  .message-meta {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    margin-block-start: var(--space-1);
    justify-content: flex-end;
  }

  .message-time {
    font-size: 11px;
    color: var(--color-text-tertiary);
  }

  .message-edited {
    font-size: 11px;
    color: var(--color-text-tertiary);
    font-style: italic;
  }

  .read-receipt {
    color: var(--color-text-tertiary);
    display: flex;
    align-items: center;
  }

  .read-receipt.read {
    color: var(--color-primary);
  }

  .pending {
    opacity: 0.6;
  }

  .message-pending {
    font-size: 10px;
    color: var(--color-text-tertiary);
    font-style: italic;
  }

  /* Reactions sit half-outside the bubble's bottom edge — anchor
     to the inside-corner so the chip overlaps the rounded edge. */
  .reactions-overlay {
    position: absolute;
    inset-block-end: -12px;
    display: flex;
    gap: 3px;
    z-index: 1;
    pointer-events: none;
  }

  .reactions-overlay :global(.msg-reaction) {
    pointer-events: auto;
  }

  /* Other party's bubble — chips bleed out the bottom-LEFT corner. */
  .reactions-overlay {
    inset-inline-start: 12px;
  }

  /* Own bubble (right side) — bleed out the bottom-RIGHT instead. */
  .overlay-own {
    inset-inline-start: auto;
    inset-inline-end: 12px;
  }

  .msg-reaction {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    padding: 2px 6px;
    border-radius: 9999px;
    background: var(--color-surface-raised, var(--color-surface));
    border: 1px solid var(--color-border);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08);
    font-size: 0.875rem;
    line-height: 1;
    cursor: default;
  }

  .msg-reaction-char {
    font-size: 14px;
    line-height: 1;
  }

  .msg-reaction-img {
    width: 16px;
    height: 16px;
    object-fit: contain;
    display: block;
  }

  .msg-reaction-fallback {
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 0.6875rem;
    color: var(--color-text-tertiary);
  }

  .msg-reaction-count {
    font-size: 0.6875rem;
    font-weight: 700;
    color: var(--color-text-secondary);
    margin-inline-start: 2px;
  }
</style>
