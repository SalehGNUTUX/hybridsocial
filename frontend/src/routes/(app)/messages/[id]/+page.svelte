<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import type { Conversation, Message } from '$lib/api/types.js';
  import {
    getConversation,
    getMessages,
    sendMessage,
    markConversationRead,
    deleteConversation,
    deleteMessage as apiDeleteMessage,
    addMessageReaction,
    editMessage as apiEditMessage,
  } from '$lib/api/conversations.js';
  import { markConversationReadLocal } from '$lib/stores/dm-unread.js';
  import { currentUser } from '$lib/stores/auth.js';
  import MessageBubble from '$lib/components/dm/MessageBubble.svelte';
  import MessageInput from '$lib/components/dm/MessageInput.svelte';
  import TypingIndicator from '$lib/components/dm/TypingIndicator.svelte';
  import Spinner from '$lib/components/ui/Spinner.svelte';
  import ParticipantStrip from '$lib/components/dm/ParticipantStrip.svelte';
  import { addToast } from '$lib/stores/toast.js';
  import { slide } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';

  let conversation = $state<Conversation | null>(null);
  let messages = $state<Message[]>([]);
  let loading = $state(true);
  let loadingMore = $state(false);
  let sending = $state(false);
  let cursor = $state<string | null>(null);
  let hasMore = $state(true);
  let messagesEndEl: HTMLDivElement | undefined = $state();
  let typingUser = $state<string | null>(null);

  let userId = $state('');
  currentUser.subscribe((u) => {
    userId = u?.id ?? '';
  });

  let conversationId = $derived(page.params.id!);

  let otherParticipants = $derived(
    conversation?.participants.filter((p) => p.id !== userId) ?? []
  );

  let displayName = $derived(
    otherParticipants.map((p) => p.display_name || p.handle).join(', ') || 'Conversation'
  );

  let avatarUser = $derived(otherParticipants[0] ?? null);

  // SvelteKit reuses this component when navigating between conversations
  // (only the `[id]` param changes), so `onMount` never re-fires and the
  // old messages would remain on screen. Keyed on `conversationId`, the
  // effect reloads whenever the URL points to a new thread, and a token
  // lets us ignore stale responses if the user clicks another convo before
  // the previous fetch resolves.
  let loadToken = 0;

  $effect(() => {
    const cid = conversationId;
    if (!cid) return;
    const token = ++loadToken;

    // Reset per-conversation state up front so the UI doesn't flash the
    // previous chat's messages while the new one is loading.
    conversation = null;
    messages = [];
    cursor = null;
    hasMore = true;
    sending = false;
    loading = true;

    void (async () => {
      try {
        const [conv, msgResult] = await Promise.all([
          getConversation(cid),
          getMessages(cid)
        ]);
        if (token !== loadToken) return;
        conversation = conv;
        messages = msgResult.data.reverse();
        cursor = msgResult.next_cursor;
        hasMore = !!msgResult.next_cursor;
        markConversationReadLocal(cid);
        await markConversationRead(cid);
        if (token !== loadToken) return;
        scrollToBottom();
      } catch (err) {
        if (token !== loadToken) return;
        console.error('[messages] load failed', err);
        addToast('Could not load this conversation', 'error');
      } finally {
        if (token === loadToken) loading = false;
      }
    })();
  });

  onMount(() => {
    window.addEventListener('chat-event', handleChatEvent as EventListener);
    return () => {
      window.removeEventListener('chat-event', handleChatEvent as EventListener);
    };
  });

  function handleChatEvent(ev: Event) {
    const detail = (ev as CustomEvent<{ type: string; data: Record<string, unknown> }>).detail;
    if (!detail) return;

    const data = detail.data;
    if (data?.conversation_id !== conversationId) return;

    switch (detail.type) {
      case 'chat.new_message':
        appendLiveMessage(data as unknown as Message);
        break;
      case 'chat.read':
        // Other participant marked read — nothing to render here yet.
        break;
      case 'chat.reaction_added':
      case 'chat.reaction_removed':
        applyReactionDelta(data as { message_id: string; reactions?: Message['reactions'] });
        break;
    }
  }

  function appendLiveMessage(incoming: Message) {
    // Outbound echoes: the user already sees their own bubble from the
    // optimistic `handleSend` append, so skip duplicates keyed by id.
    if (messages.some((m) => m.id === incoming.id)) return;
    messages = [...messages, incoming];
    scrollToBottom();
    // Eagerly mark read so the badge doesn't linger while the tab is focused.
    if (incoming.sender.id !== userId) {
      void markConversationRead(conversationId);
    }
  }

  function applyReactionDelta({
    message_id,
    reactions,
  }: {
    message_id: string;
    reactions?: Message['reactions'];
  }) {
    if (!reactions) return;
    messages = messages.map((m) => (m.id === message_id ? { ...m, reactions } : m));
  }

  async function loadMore() {
    if (!cursor || !hasMore || loadingMore) return;
    loadingMore = true;
    try {
      const result = await getMessages(conversationId, cursor);
      messages = [...result.data.reverse(), ...messages];
      cursor = result.next_cursor;
      hasMore = !!result.next_cursor;
    } catch {
      // Error loading more
    } finally {
      loadingMore = false;
    }
  }

  async function handleSend(content: string) {
    if (sending) return;
    sending = true;
    // Defense-in-depth watchdog: if something in the promise chain
    // somehow leaves `sending` stuck (past bug: silent rejection on
    // token refresh race), force-unstick after a reasonable timeout
    // so the composer never requires a page refresh to work again.
    const watchdog = window.setTimeout(() => {
      if (sending) {
        console.warn('[messages] send watchdog fired; resetting sending flag');
        sending = false;
        addToast('Send timed out. Please try again.', 'error');
      }
    }, 10_000);
    try {
      const msg = await sendMessage(conversationId, { content });
      messages = [...messages, msg];
      triggerRipple();
      scrollToBottom();
    } catch (err) {
      console.error('[messages] send failed', err);
      addToast('Could not send message. Please try again.', 'error');
    } finally {
      window.clearTimeout(watchdog);
      sending = false;
    }
  }

  function scrollToBottom() {
    requestAnimationFrame(() => {
      messagesEndEl?.scrollIntoView({ behavior: 'smooth' });
    });
  }

  // Toggled true for ~600ms after a new bubble is appended; bubbles
  // read this via :global(.messages-container.rippling) and run a
  // brief, staggered upward bounce.
  let rippling = $state(false);
  let rippleTimer: ReturnType<typeof setTimeout> | null = null;

  function triggerRipple() {
    rippling = true;
    if (rippleTimer) clearTimeout(rippleTimer);
    rippleTimer = setTimeout(() => {
      rippling = false;
    }, 600);
  }

  function goBack() {
    goto('/messages');
  }

  let confirmingDeleteConv = $state(false);
  let deletingConv = $state(false);

  async function handleDeleteConversation() {
    if (deletingConv) return;
    deletingConv = true;
    try {
      await deleteConversation(conversationId);
      // Let the layout drop this row from the sidebar immediately
      // — the backend doesn't (yet) broadcast conversation-level
      // deletes, and a full refetch on navigate would flicker.
      window.dispatchEvent(
        new CustomEvent('conversation-deleted', { detail: { id: conversationId } }),
      );
      addToast('Conversation deleted', 'success');
      goto('/messages');
    } catch {
      addToast('Failed to delete conversation', 'error');
      deletingConv = false;
      confirmingDeleteConv = false;
    }
  }

  async function handleDeleteMessage(messageId: string) {
    try {
      await apiDeleteMessage(conversationId, messageId);
      messages = messages.filter((m) => m.id !== messageId);
    } catch {
      addToast('Failed to delete message', 'error');
    }
  }

  async function handleEditMessage(messageId: string, content: string) {
    try {
      const updated = await apiEditMessage(conversationId, messageId, content);
      messages = messages.map((m) => (m.id === messageId ? { ...m, ...updated } : m));
    } catch (e: unknown) {
      const err = e as { body?: { error?: string; message?: string } };
      if (err?.body?.error === 'message.edit_window_expired') {
        addToast(err.body.message || 'Edit window has closed', 'error');
      } else {
        addToast('Failed to edit message', 'error');
      }
      throw e;
    }
  }

  async function handleReactMessage(messageId: string, emoji: string) {
    try {
      // Backend enforces one-per-user-per-message. Response tells us
      // whether this was "added" (first reaction), "removed" (same
      // emoji toggled off), or "swapped" (replaced a previous emoji).
      // We apply the returned aggregate to the local state so the
      // count + account list match exactly what other participants
      // will see via SSE.
      const res = await addMessageReaction(conversationId, messageId, emoji);
      const nextReactions = res.reactions ?? [];
      messages = messages.map((m) =>
        m.id === messageId ? { ...m, reactions: nextReactions } : m
      );
    } catch (e: unknown) {
      const err = e as { body?: { error?: string; message?: string } };
      if (err?.body?.error === 'reaction.premium_required') {
        addToast(err.body.message || 'That reaction needs a premium tier', 'error');
      } else {
        addToast('Failed to react', 'error');
      }
    }
  }

  function shouldShowAvatar(index: number): boolean {
    if (index === messages.length - 1) return true;
    return messages[index].sender.id !== messages[index + 1].sender.id;
  }
</script>

<svelte:head>
  <title>{displayName} - Messages - HybridSocial</title>
</svelte:head>

<div class="conversation-detail">
  <div class="detail-header">
    <button type="button" class="back-btn" onclick={goBack} aria-label="Back to messages">
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <polyline points="15 18 9 12 15 6" />
      </svg>
    </button>

    <div class="detail-header-strip">
      <ParticipantStrip participants={otherParticipants} />
    </div>

    <div class="detail-header-meta">
      {#if conversation?.encryption_status === 'e2ee'}
        <span
          class="material-symbols-outlined header-encryption header-e2ee"
          title="End-to-end encrypted. Only participants can read."
          aria-label="End-to-end encrypted"
        >lock</span>
      {:else if conversation?.encryption_status === 'at_rest'}
        <span
          class="material-symbols-outlined header-encryption header-at-rest"
          title="Stored encrypted on our servers. Not end-to-end — the server can decrypt."
          aria-label="Encrypted at rest"
        >lock</span>
      {:else if conversation?.encryption_status === 'federated'}
        <span
          class="material-symbols-outlined header-encryption header-federated"
          title="Not encrypted — the other server received plaintext. DMs with remote users are not private."
          aria-label="Not encrypted (federated)"
        >lock_open</span>
      {/if}
    </div>

    <div class="detail-header-actions">
      <button
        type="button"
        class="header-action header-action-danger"
        onclick={() => (confirmingDeleteConv = true)}
        title="Delete conversation"
        aria-label="Delete conversation"
      >
        <span class="material-symbols-outlined">delete</span>
        <span class="header-action-label">Delete</span>
      </button>
    </div>
  </div>

  {#if confirmingDeleteConv}
    <div
      class="confirm-banner"
      role="alertdialog"
      aria-live="polite"
      transition:slide={{ duration: 200, easing: cubicOut }}
    >
      <span>
        Delete this conversation from your inbox? The other person
        keeps their copy. You can't undo this for yourself.
      </span>
      <div class="confirm-actions">
        <button
          type="button"
          class="btn btn-ghost"
          onclick={() => (confirmingDeleteConv = false)}
          disabled={deletingConv}
        >
          Cancel
        </button>
        <button
          type="button"
          class="btn btn-danger"
          onclick={handleDeleteConversation}
          disabled={deletingConv}
        >
          {deletingConv ? 'Deleting…' : 'Delete'}
        </button>
      </div>
    </div>
  {/if}

  {#if loading}
    <div class="detail-loading">
      <Spinner />
    </div>
  {:else}
    <div class="messages-container" class:rippling role="log" aria-label="Messages">
      {#if hasMore && messages.length > 0}
        <button type="button" class="load-more-btn" onclick={loadMore} disabled={loadingMore}>
          {loadingMore ? 'Loading...' : 'Load older messages'}
        </button>
      {/if}

      {#each messages as message, i (message.id)}
        <div class="bubble-slot" style="--ripple-i: {messages.length - 1 - i}">
          <MessageBubble
            {message}
            isOwn={message.sender.id === userId}
            showAvatar={shouldShowAvatar(i)}
            ondelete={handleDeleteMessage}
            onreact={handleReactMessage}
            onedit={handleEditMessage}
          />
        </div>
      {/each}

      {#if typingUser}
        <TypingIndicator name={typingUser} />
      {/if}

      <div bind:this={messagesEndEl} class="messages-end" aria-hidden="true"></div>
    </div>

    <MessageInput onsend={handleSend} disabled={sending} />
  {/if}
</div>

<style>
  .conversation-detail {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
    overflow: hidden;
  }

  .detail-header {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-3) var(--space-4);
    border-block-end: 1px solid var(--color-border);
    flex-shrink: 0;
  }

  .detail-header-strip {
    flex: 1;
    min-width: 0;
  }

  .detail-header-meta {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    flex-shrink: 0;
  }

  .detail-header-actions {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }

  .header-action {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: 9999px;
    font-size: var(--text-sm);
    font-weight: 500;
    color: var(--color-text-secondary);
    cursor: pointer;
    transition:
      background-color var(--transition-fast),
      color var(--transition-fast),
      border-color var(--transition-fast),
      transform var(--transition-fast);
  }

  .header-action:active {
    transform: scale(0.96);
  }

  .header-action:hover {
    background: var(--color-surface);
    color: var(--color-text);
  }

  .header-action .material-symbols-outlined {
    font-size: 18px !important;
  }

  .header-action-danger:hover {
    color: var(--color-danger, #b00);
    border-color: var(--color-danger, #b00);
    background: var(--color-danger-surface, rgba(176, 0, 0, 0.06));
  }

  /* Hide the text label on narrow viewports — icon alone is enough. */
  @media (max-width: 480px) {
    .header-action-label {
      display: none;
    }
  }

  .confirm-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    padding: var(--space-3) var(--space-4);
    background: var(--color-warning-surface, rgba(217, 119, 6, 0.08));
    border-block-end: 1px solid var(--color-warning, #d97706);
    font-size: var(--text-sm);
  }

  .confirm-actions {
    display: flex;
    gap: var(--space-2);
    flex-shrink: 0;
  }

  .back-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    border: none;
    background: none;
    border-radius: var(--radius-full);
    color: var(--color-text-secondary);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .back-btn:hover {
    background: var(--color-surface);
  }


  .header-encryption {
    font-size: 16px;
  }

  .header-at-rest {
    color: var(--color-warning, #d97706);
  }

  .header-federated {
    color: var(--color-danger, #dc2626);
  }

  .header-e2ee {
    color: var(--color-success, #16a34a);
  }

  .detail-loading {
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 1;
  }

  .messages-container {
    flex: 1;
    overflow-y: auto;
    padding: var(--space-4);
    display: flex;
    flex-direction: column;
  }

  .load-more-btn {
    align-self: center;
    padding: var(--space-2) var(--space-4);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-full);
    background: var(--color-surface);
    color: var(--color-text-secondary);
    font-size: var(--text-xs);
    cursor: pointer;
    transition: background var(--transition-fast);
    margin-block-end: var(--space-4);
  }

  .load-more-btn:hover:not(:disabled) {
    background: var(--color-surface-raised);
  }

  .load-more-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .messages-end {
    height: 1px;
  }

  /* Desktop: hide back button since split view is available */
  @media (min-width: 769px) {
    .back-btn {
      display: none;
    }
  }

</style>
