<script lang="ts">
  import { onMount } from 'svelte';
  import { addToast } from '$lib/stores/toast.js';
  import { getSessions, revokeSession, revokeOtherSessions } from '$lib/api/sessions.js';
  import type { Session } from '$lib/api/sessions.js';
  import Spinner from '$lib/components/ui/Spinner.svelte';
  import Modal from '$lib/components/ui/Modal.svelte';

  let sessions: Session[] = $state([]);
  let loading = $state(true);

  // Revoking a session signs a device out — confirm before doing it.
  let confirmTarget = $state<{ kind: 'one'; session: Session } | { kind: 'all' } | null>(null);
  let showConfirm = $state(false);
  let working = $state(false);

  onMount(async () => {
    try {
      sessions = await getSessions();
    } catch {
      addToast('Failed to load sessions', 'error');
    } finally {
      loading = false;
    }
  });

  function askRevoke(session: Session) {
    confirmTarget = { kind: 'one', session };
    showConfirm = true;
  }

  function askRevokeOthers() {
    confirmTarget = { kind: 'all' };
    showConfirm = true;
  }

  let otherCount = $derived(sessions.filter((s) => !s.current).length);

  async function executeConfirm() {
    if (!confirmTarget || working) return;
    working = true;
    try {
      if (confirmTarget.kind === 'one') {
        const id = confirmTarget.session.id;
        await revokeSession(id);
        sessions = sessions.filter((s) => s.id !== id);
        addToast('Session revoked', 'success');
      } else {
        const result = await revokeOtherSessions();
        sessions = sessions.filter((s) => s.current);
        addToast(`Revoked ${result.count} other session${result.count === 1 ? '' : 's'}`, 'success');
      }
      showConfirm = false;
      confirmTarget = null;
    } catch {
      addToast('Failed to revoke session', 'error');
    } finally {
      working = false;
    }
  }

  function timeAgo(iso: string | null): string {
    if (!iso) return 'Never';
    const diff = Date.now() - new Date(iso).getTime();
    const minutes = Math.floor(diff / 60000);
    if (minutes < 1) return 'Just now';
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ago`;
    const days = Math.floor(hours / 24);
    return `${days}d ago`;
  }
</script>

<div class="stitch-settings">
  <section class="stitch-section">
    <div class="stitch-section-heading">
      <span class="stitch-section-icon" aria-hidden="true">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>
        </svg>
      </span>
      <h2 class="stitch-section-title">Sessions</h2>
    </div>

    <div class="stitch-section-content">
      <div class="stitch-form">
        <p class="stitch-description">
          These are the devices currently logged into your account. Revoke any session you don't recognise.
        </p>

        {#if loading}
          <div class="stitch-loading"><Spinner size={20} /> Loading sessions...</div>
        {:else if sessions.length === 0}
          <p class="stitch-description">No active sessions found.</p>
        {:else}
          <div class="stitch-sessions-list">
            {#each sessions as session (session.id)}
              <div class="stitch-session" class:stitch-session-current={session.current}>
                <div class="stitch-session-icon">
                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    {#if session.device_name?.includes('Android') || session.device_name?.includes('iOS')}
                      <rect x="5" y="2" width="14" height="20" rx="2" ry="2"/><line x1="12" y1="18" x2="12.01" y2="18"/>
                    {:else}
                      <rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>
                    {/if}
                  </svg>
                </div>
                <div class="stitch-session-info">
                  <div class="stitch-session-name">
                    {session.device_name}
                    {#if session.current}
                      <span class="stitch-session-badge">This device</span>
                    {/if}
                  </div>
                  <div class="stitch-session-meta">
                    {#if session.location}
                      <span>{session.location}</span>
                      <span class="stitch-session-dot">&middot;</span>
                    {/if}
                    {#if session.ip_address}
                      <span>{session.ip_address}</span>
                      <span class="stitch-session-dot">&middot;</span>
                    {/if}
                    <span>Active {timeAgo(session.last_active_at)}</span>
                  </div>
                </div>
                {#if !session.current}
                  <button
                    class="stitch-session-revoke"
                    onclick={() => askRevoke(session)}
                  >
                    Revoke
                  </button>
                {/if}
              </div>
            {/each}
          </div>

          {#if otherCount > 0}
            <div class="stitch-actions">
              <button
                class="stitch-btn-danger stitch-btn-sm"
                onclick={askRevokeOthers}
              >
                Revoke all other sessions
              </button>
            </div>
          {/if}
        {/if}
      </div>
    </div>
  </section>
</div>

<Modal
  bind:open={showConfirm}
  title={confirmTarget?.kind === 'all' ? 'Revoke all other sessions?' : 'Revoke this session?'}
  onclose={() => { confirmTarget = null; }}
>
  {#if confirmTarget}
    <p class="confirm-message">
      {#if confirmTarget.kind === 'all'}
        This signs out {otherCount} other device{otherCount === 1 ? '' : 's'}. They'll need to log in again. Your current device stays signed in.
      {:else}
        <strong>{confirmTarget.session.device_name}</strong> will be signed out and need to log in again.
      {/if}
    </p>
    <div class="confirm-actions">
      <button type="button" class="stitch-btn-ghost" onclick={() => (showConfirm = false)}>Cancel</button>
      <button type="button" class="stitch-btn-danger" onclick={executeConfirm} disabled={working}>
        {#if working}<Spinner size={14} color="#fff" />{/if}
        Revoke
      </button>
    </div>
  {/if}
</Modal>

<style>
  .stitch-settings {
    max-width: 720px;
  }

  .confirm-message {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    line-height: 1.5;
    margin-block-end: var(--space-4);
  }

  .confirm-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
  }

  .stitch-btn-ghost {
    padding: 10px 20px;
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: 9999px;
    color: var(--color-text);
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
  }

  .stitch-btn-ghost:hover {
    background: var(--color-surface-container-low);
  }

  .stitch-section {
    margin-block-end: 24px;
  }

  .stitch-section-heading {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-block-end: 16px;
  }

  .stitch-section-icon {
    color: var(--color-primary);
    display: flex;
    align-items: center;
  }

  .stitch-section-title {
    font-size: 1.125rem;
    font-weight: 700;
    color: var(--color-text);
    margin: 0;
  }

  .stitch-section-content {
    background: var(--color-surface-container-low);
    border-radius: 16px;
    overflow: hidden;
  }

  .stitch-form {
    padding: 24px 32px 32px;
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .stitch-description {
    font-size: 0.875rem;
    color: var(--color-text-secondary);
    line-height: 1.5;
  }

  .stitch-loading {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.875rem;
    color: var(--color-text-secondary);
  }

  .stitch-sessions-list {
    display: flex;
    flex-direction: column;
    gap: 1px;
    background: var(--scrim-soft);
    border-radius: 12px;
    overflow: hidden;
  }

  .stitch-session {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 16px;
    background: var(--color-surface-container-high);
  }

  .stitch-session-current {
    background: rgba(var(--color-primary-rgb), 0.08);
  }

  .stitch-session-icon {
    color: var(--color-text-secondary);
    flex-shrink: 0;
  }

  .stitch-session-current .stitch-session-icon {
    color: var(--color-primary);
  }

  .stitch-session-info {
    flex: 1;
    min-width: 0;
  }

  .stitch-session-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--color-text);
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .stitch-session-badge {
    font-size: 0.625rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    color: var(--color-primary);
    background: var(--color-surface-container-lowest);
    padding: 1px 8px;
    border-radius: 9999px;
  }

  .stitch-session-meta {
    font-size: 0.75rem;
    color: var(--color-text-tertiary);
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .stitch-session-dot {
    font-size: 0.75rem;
  }

  .stitch-session-revoke {
    flex-shrink: 0;
    padding: 4px 12px;
    background: transparent;
    border: none;
    border-radius: 9999px;
    color: var(--color-danger);
    font-size: 0.75rem;
    font-weight: 600;
    cursor: pointer;
    transition: background-color 0.15s ease;
    display: inline-flex;
    align-items: center;
    gap: 4px;
  }

  .stitch-session-revoke:hover:not(:disabled) {
    background: var(--color-danger-soft);
  }

  .stitch-session-revoke:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .stitch-actions {
    display: flex;
    justify-content: flex-end;
    gap: 12px;
    padding-block-start: 8px;
  }

  .stitch-btn-danger {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 10px 24px;
    background: var(--color-danger);
    color: white;
    border: none;
    border-radius: 9999px;
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
    transition: background-color 0.15s ease, transform 0.1s ease;
  }

  .stitch-btn-danger:hover:not(:disabled) {
    background: #b91c1c;
  }

  .stitch-btn-danger:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .stitch-btn-sm {
    padding: 6px 16px;
    font-size: 0.75rem;
  }

  @media (max-width: 640px) {
    .stitch-form {
      padding: 20px;
    }
  }
</style>
