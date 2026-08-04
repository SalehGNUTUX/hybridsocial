<script lang="ts">
  import { onMount } from 'svelte';
  import {
    getMyTakedowns,
    appealTakedown,
    type Takedown,
    type TakedownTargetType,
    type TakedownStatus,
  } from '$lib/api/takedowns.js';
  import { ApiError } from '$lib/api/client.js';
  import { addToast } from '$lib/stores/toast.js';
  import Modal from '$lib/components/ui/Modal.svelte';
  import { t } from '$lib/stores/i18n.js';
  import { t as ti } from '$lib/utils/i18n.js';

  let takedowns = $state<Takedown[]>([]);
  let loading = $state(true);
  let loadError = $state(false);

  // Appeal modal state.
  let appealing = $state<Takedown | null>(null);
  let appealReason = $state('');
  let submitting = $state(false);
  let appealError = $state('');

  const MIN_REASON = 10;

  async function load() {
    loading = true;
    loadError = false;
    try {
      takedowns = await getMyTakedowns();
    } catch {
      loadError = true;
    } finally {
      loading = false;
    }
  }

  onMount(load);

  const TARGET_KEY: Record<TakedownTargetType, string> = {
    group: 'mod_appeal.target_group',
    page: 'mod_appeal.target_page',
    post: 'mod_appeal.target_post',
    media: 'mod_appeal.target_media',
    account_badge: 'mod_appeal.target_account_badge',
  };

  function targetKey(type: TakedownTargetType): string {
    return TARGET_KEY[type] ?? 'mod_appeal.target_content';
  }

  const STATUS_KEY: Record<TakedownStatus, string> = {
    active: 'mod_appeal.status_active',
    appealed: 'mod_appeal.status_appealed',
    restored: 'mod_appeal.status_restored',
    purged: 'mod_appeal.status_purged',
  };

  function fmtDate(iso: string | null): string {
    if (!iso) return '';
    const d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  }

  // Whole days from now until the purge deadline (floored, never negative).
  function daysUntilPurge(iso: string | null): number | null {
    if (!iso) return null;
    const t = new Date(iso).getTime();
    if (isNaN(t)) return null;
    return Math.max(0, Math.floor((t - Date.now()) / 86_400_000));
  }

  function openAppeal(t: Takedown) {
    appealing = t;
    appealReason = '';
    appealError = '';
  }

  function closeAppeal() {
    appealing = null;
    appealReason = '';
    appealError = '';
  }

  async function submitAppeal() {
    if (!appealing || submitting) return;
    const reason = appealReason.trim();
    if (reason.length < MIN_REASON) return;
    submitting = true;
    appealError = '';
    const target = appealing;
    try {
      await appealTakedown(target.id, reason);
      // Reflect the new state locally: an active takedown becomes "appealed".
      takedowns = takedowns.map((t) => (t.id === target.id ? { ...t, status: 'appealed' } : t));
      addToast(ti('mod_appeal.submitted'), 'success');
      closeAppeal();
    } catch (e) {
      if (e instanceof ApiError) {
        switch (e.body.error) {
          case 'appeal.already_pending':
            appealError = ti('mod_appeal.err_duplicate');
            break;
          case 'takedown.not_appealable':
            appealError = ti('mod_appeal.err_closed');
            break;
          case 'takedown.forbidden':
            appealError = ti('mod_appeal.err_forbidden');
            break;
          case 'takedown.not_found':
            appealError = ti('mod_appeal.err_missing');
            break;
          default:
            appealError = e.message || ti('mod_appeal.err_generic');
        }
      } else {
        appealError = ti('mod_appeal.err_generic');
      }
    } finally {
      submitting = false;
    }
  }
</script>

<div class="mod-page">
  <p class="mod-intro">{$t('mod_appeal.intro')}</p>

  {#if loading}
    <ul class="mod-list" aria-hidden="true">
      {#each Array(2) as _, i (i)}
        <li class="mod-card skel">
          <span class="skel-line skel-lg"></span>
          <span class="skel-line skel-sm"></span>
          <span class="skel-line skel-md"></span>
        </li>
      {/each}
    </ul>
  {:else if loadError}
    <div class="mod-empty">
      <p class="empty-title">{$t('mod_appeal.load_error_title')}</p>
      <p class="empty-hint">{$t('mod_appeal.load_error_hint')}</p>
      <button type="button" class="btn btn-primary" onclick={load}>{$t('common.retry')}</button>
    </div>
  {:else if takedowns.length === 0}
    <div class="mod-empty">
      <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="var(--color-success)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" /><path d="M9 12l2 2 4-4" />
      </svg>
      <p class="empty-title">{$t('mod_appeal.empty_title')}</p>
      <p class="empty-hint">{$t('mod_appeal.empty_hint')}</p>
    </div>
  {:else}
    <ul class="mod-list">
      {#each takedowns as td (td.id)}
        {@const days = daysUntilPurge(td.purge_after)}
        <li class="mod-card">
          <div class="mod-card-head">
            <span class="mod-target">{$t(targetKey(td.target_type))}</span>
            <span class="mod-status mod-status-{td.status}">{$t(STATUS_KEY[td.status])}</span>
          </div>

          {#if td.reason}
            <p class="mod-reason"><span class="mod-label">{$t('mod_appeal.reason_label')}</span> {td.reason}</p>
          {:else}
            <p class="mod-reason mod-reason-none">{$t('mod_appeal.no_reason')}</p>
          {/if}

          <p class="mod-meta">{$t('mod_appeal.removed_at', { date: fmtDate(td.created_at) })}</p>

          {#if td.status === 'active'}
            {#if days !== null}
              <p class="mod-deadline" class:mod-deadline-urgent={days <= 7}>
                {#if days === 0}
                  {$t('mod_appeal.purge_today')}
                {:else}
                  {$t('mod_appeal.purge_in_pre')} <strong>{days === 1 ? $t('mod_appeal.days_one') : $t('mod_appeal.days_other', { days })}</strong> {$t('mod_appeal.purge_in_post', { date: fmtDate(td.purge_after) })}
                {/if}
              </p>
            {/if}
            <div class="mod-actions">
              <button type="button" class="btn btn-primary btn-sm" onclick={() => openAppeal(td)}>
                {$t('mod_appeal.appeal_this')}
              </button>
            </div>
          {:else if td.status === 'appealed'}
            <p class="mod-note">{$t('mod_appeal.note_appealed')}</p>
          {:else if td.status === 'restored'}
            <p class="mod-note mod-note-good">{$t('mod_appeal.note_restored')}</p>
          {:else if td.status === 'purged'}
            <p class="mod-note mod-note-final">{$t('mod_appeal.note_purged')}</p>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</div>

<Modal open={appealing !== null} title={$t('mod_appeal.modal_title')} size="sm" onclose={closeAppeal}>
  {#if appealing}
    <p class="appeal-lead">
      {$t('mod_appeal.modal_lead', { target: $t(targetKey(appealing.target_type)).toLowerCase() })}
    </p>
    <div class="appeal-field">
      <textarea
        bind:value={appealReason}
        rows="5"
        maxlength="2000"
        placeholder={$t('mod_appeal.placeholder')}
        aria-label={$t('mod_appeal.textarea_label')}
        disabled={submitting}
      ></textarea>
    </div>
    <div class="appeal-foot">
      <span class="appeal-count" class:appeal-count-short={appealReason.trim().length < MIN_REASON}>
        {appealReason.trim().length < MIN_REASON
          ? $t('mod_appeal.min_chars', { min: MIN_REASON })
          : $t('mod_appeal.char_count', { count: appealReason.trim().length })}
      </span>
    </div>
    {#if appealError}
      <p class="appeal-error">{appealError}</p>
    {/if}
    <div class="appeal-actions">
      <button type="button" class="btn btn-ghost" onclick={closeAppeal} disabled={submitting}>{$t('common.cancel')}</button>
      <button
        type="button"
        class="btn btn-primary"
        onclick={submitAppeal}
        disabled={submitting || appealReason.trim().length < MIN_REASON}
      >
        {submitting ? $t('mod_appeal.submitting') : $t('mod_appeal.submit')}
      </button>
    </div>
  {/if}
</Modal>

<style>
  .mod-page {
    display: flex;
    flex-direction: column;
    gap: var(--space-4, 16px);
  }

  .mod-intro {
    color: var(--color-text-secondary);
    font-size: var(--text-sm, 0.875rem);
    line-height: 1.5;
    margin: 0;
  }

  .mod-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-3, 12px);
  }

  .mod-card {
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 8px);
    background: var(--color-surface);
    padding: var(--space-4, 16px);
    display: flex;
    flex-direction: column;
    gap: var(--space-2, 8px);
  }

  .mod-card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-2, 8px);
  }

  .mod-target {
    font-weight: 600;
  }

  .mod-status {
    font-size: var(--text-xs, 0.75rem);
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 999px;
    white-space: nowrap;
  }

  .mod-status-active {
    background: var(--color-warning-border, rgba(180, 120, 0, 0.15));
    color: var(--color-warning, #9a6b00);
  }

  .mod-status-appealed {
    background: var(--color-primary-soft, rgba(0, 100, 200, 0.12));
    color: var(--color-primary);
  }

  .mod-status-restored {
    background: var(--color-success-soft, rgba(0, 150, 80, 0.12));
    color: var(--color-success);
  }

  .mod-status-purged {
    background: var(--color-danger-soft, rgba(200, 40, 40, 0.12));
    color: var(--color-danger);
  }

  .mod-reason {
    margin: 0;
    font-size: var(--text-sm, 0.875rem);
    line-height: 1.5;
    word-break: break-word;
  }

  .mod-reason-none {
    color: var(--color-text-tertiary);
    font-style: italic;
  }

  .mod-label {
    font-weight: 600;
    color: var(--color-text-secondary);
  }

  .mod-meta {
    margin: 0;
    font-size: var(--text-xs, 0.75rem);
    color: var(--color-text-tertiary);
  }

  .mod-deadline {
    margin: 0;
    font-size: var(--text-sm, 0.875rem);
    color: var(--color-text-secondary);
  }

  .mod-deadline-urgent {
    color: var(--color-danger);
  }

  .mod-actions {
    margin-top: var(--space-1, 4px);
  }

  .mod-note {
    margin: 0;
    font-size: var(--text-sm, 0.875rem);
    color: var(--color-text-secondary);
  }

  .mod-note-good {
    color: var(--color-success);
  }

  .mod-note-final {
    color: var(--color-text-tertiary);
  }

  .mod-empty {
    text-align: center;
    padding: var(--space-6, 32px) var(--space-4, 16px);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-2, 8px);
  }

  .empty-title {
    font-weight: 600;
    margin: var(--space-2, 8px) 0 0;
  }

  .empty-hint {
    color: var(--color-text-secondary);
    font-size: var(--text-sm, 0.875rem);
    max-width: 42ch;
    margin: 0 0 var(--space-2, 8px);
    line-height: 1.5;
  }

  /* Appeal modal */
  .appeal-lead {
    margin: 0 0 var(--space-3, 12px);
    font-size: var(--text-sm, 0.875rem);
    color: var(--color-text-secondary);
    line-height: 1.5;
  }

  .appeal-field textarea {
    width: 100%;
    resize: vertical;
    padding: var(--space-2, 8px) var(--space-3, 12px);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 8px);
    background: var(--color-surface);
    color: var(--color-text);
    font: inherit;
    line-height: 1.5;
  }

  .appeal-field textarea:focus-visible {
    outline: none;
    border-color: var(--color-primary);
  }

  .appeal-foot {
    display: flex;
    justify-content: flex-end;
    margin-top: var(--space-1, 4px);
  }

  .appeal-count {
    font-size: var(--text-xs, 0.75rem);
    color: var(--color-text-tertiary);
  }

  .appeal-count-short {
    color: var(--color-danger);
  }

  .appeal-error {
    margin: var(--space-2, 8px) 0 0;
    font-size: var(--text-sm, 0.875rem);
    color: var(--color-danger);
  }

  .appeal-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2, 8px);
    margin-top: var(--space-4, 16px);
  }

  /* Skeleton */
  .skel {
    gap: var(--space-2, 8px);
  }

  .skel-line {
    display: block;
    height: 12px;
    border-radius: 6px;
    background: var(--color-surface-alt, rgba(0, 0, 0, 0.06));
    animation: skel-pulse 1.4s ease-in-out infinite;
  }

  .skel-lg {
    width: 40%;
  }
  .skel-md {
    width: 70%;
  }
  .skel-sm {
    width: 55%;
  }

  @keyframes skel-pulse {
    0%,
    100% {
      opacity: 1;
    }
    50% {
      opacity: 0.5;
    }
  }
</style>
