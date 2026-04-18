<script lang="ts">
  import { onMount } from 'svelte';
  import { addToast } from '$lib/stores/toast.js';
  import { getBackups, createBackup, backupDownloadUrl, restoreBackup, deleteBackup } from '$lib/api/admin.js';
  import type { Backup } from '$lib/api/types.js';
  import Modal from '$lib/components/ui/Modal.svelte';

  let backups: Backup[] = $state([]);
  let loading = $state(true);
  let creating = $state(false);
  let passphrase = $state('');
  let showPassphrase = $state(false);

  function generatePassphrase(): string {
    const words = ['alpha','bravo','coral','delta','eagle','frost','grove','haven','ivory','jewel','karma','lunar','maple','noble','ocean','pearl','quest','ridge','solar','tiger','ultra','vivid','waker','xenon','yield','zephyr'];
    const parts: string[] = [];
    for (let i = 0; i < 4; i++) {
      parts.push(words[Math.floor(Math.random() * words.length)]);
    }
    // Add a random 2-digit number for entropy
    parts.push(String(Math.floor(Math.random() * 90) + 10));
    return parts.join('-');
  }

  onMount(async () => {
    try {
      backups = await getBackups();
    } catch {
      addToast('Failed to load backups', 'error');
    } finally {
      loading = false;
    }
  });

  async function handleCreate() {
    creating = true;
    try {
      const backup = await createBackup(passphrase || undefined);
      backups = [backup, ...backups];
      passphrase = '';
      addToast('Backup creation started', 'success');
    } catch {
      addToast('Failed to create backup', 'error');
    } finally {
      creating = false;
    }
  }

  // Restore confirmation modal state. The backend also enforces a
  // confirmation string, so even a direct API call can't miss the
  // warning.
  let restoreModalOpen = $state(false);
  let restoreTarget: Backup | null = $state(null);
  let restorePassphrase = $state('');
  let restoreConfirmation = $state('');
  let restoreSubmitting = $state(false);

  function openRestoreModal(backup: Backup) {
    restoreTarget = backup;
    restorePassphrase = '';
    restoreConfirmation = '';
    restoreModalOpen = true;
  }

  async function handleDelete(backup: Backup) {
    if (!confirm(`Delete this backup permanently? The encrypted file and its record will be removed.`)) return;
    try {
      await deleteBackup(backup.id);
      backups = backups.filter((b) => b.id !== backup.id);
      addToast('Backup deleted', 'success');
    } catch {
      addToast('Failed to delete backup', 'error');
    }
  }

  async function handleRestore() {
    if (!restoreTarget) return;
    if (restoreConfirmation !== 'RESTORE') {
      addToast('Type RESTORE to confirm', 'error');
      return;
    }
    restoreSubmitting = true;
    try {
      const res = await restoreBackup(restoreTarget.id, restorePassphrase, restoreConfirmation);
      addToast(res.message || 'Database restored', 'success');
      restoreModalOpen = false;
    } catch (e: any) {
      const msg =
        e?.body?.message ||
        e?.body?.output ||
        (e?.body?.error === 'backup.invalid_passphrase' ? 'Passphrase did not decrypt the backup.' : null) ||
        (e?.body?.error === 'backup.decryption_failed' ? 'Decryption failed — wrong passphrase or corrupted file.' : null) ||
        'Failed to restore backup';
      addToast(msg, 'error');
    } finally {
      restoreSubmitting = false;
    }
  }

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleDateString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  }

  function formatSize(bytes: number | null | undefined): string {
    if (bytes == null) return '-';
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
  }

  function statusIcon(status: string): string {
    switch (status) {
      case 'completed': return 'status-success';
      case 'in_progress': case 'pending': return 'status-pending';
      case 'failed': return 'status-failed';
      default: return '';
    }
  }
</script>

<svelte:head>
  <title>Backups - Admin</title>
</svelte:head>

<div class="backups-page">
  <h1 class="page-title">Backups</h1>

  <section class="card create-section">
    <h2 class="section-title">Create Backup</h2>
    <p class="section-desc">
      Create an encrypted backup of your instance data.
      Backups are retained for <strong>30 days</strong> — older files are pruned automatically by the backup expiry worker.
    </p>
    <form class="create-form" onsubmit={(e) => { e.preventDefault(); handleCreate(); }}>
      <div class="passphrase-field">
        <label for="passphrase" class="field-label">Encryption Passphrase (optional)</label>
        <div class="passphrase-input-row">
          <input
            id="passphrase"
            type={showPassphrase ? 'text' : 'password'}
            class="input"
            bind:value={passphrase}
            placeholder="Enter passphrase..."
          />
          <button
            class="btn btn-ghost btn-sm"
            type="button"
            onclick={() => (showPassphrase = !showPassphrase)}
          >{showPassphrase ? 'Hide' : 'Show'}</button>
          <button
            class="btn btn-ghost btn-sm"
            type="button"
            onclick={() => { passphrase = generatePassphrase(); showPassphrase = true; }}
          >Generate</button>
        </div>
      </div>
      <button class="btn btn-primary" type="submit" disabled={creating}>
        {creating ? 'Creating...' : 'Create Backup'}
      </button>
    </form>
  </section>

  <section class="card">
    <h2 class="section-title">Backup History</h2>

    {#if loading}
      {#each Array(3) as _}
        <div class="skeleton" style="height: 56px; margin-bottom: 8px"></div>
      {/each}
    {:else if backups.length === 0}
      <p class="empty-text">No backups found</p>
    {:else}
      <div class="backup-list">
        {#each backups as backup (backup.id)}
          <div class="backup-item">
            <div class="backup-info">
              <span class="backup-status {statusIcon(backup.status)}">
                {backup.status.replace(/_/g, ' ')}
              </span>
              <span class="backup-date">{formatDate(backup.created_at)}</span>
              <span class="backup-size">{formatSize(backup.file_size ?? backup.size)}</span>
            </div>
            <div class="backup-actions">
              {#if backup.status === 'completed'}
                <a href={backupDownloadUrl(backup.id)} class="btn btn-sm btn-outline" download>
                  Download
                </a>
                <button class="btn btn-sm btn-danger" type="button" onclick={() => openRestoreModal(backup)}>
                  Restore
                </button>
              {:else if backup.status === 'in_progress' || backup.status === 'pending'}
                <span class="text-secondary" style="font-size: var(--text-xs)">Processing...</span>
              {:else if backup.status === 'failed'}
                <span class="text-danger" style="font-size: var(--text-xs)">Failed</span>
              {/if}
              <button class="btn btn-sm btn-ghost btn-danger-text" type="button" onclick={() => handleDelete(backup)}>
                Delete
              </button>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </section>
</div>

<Modal bind:open={restoreModalOpen} title="Restore from backup">
  {#if restoreTarget}
    <div class="restore-warning" role="alert">
      <div class="restore-warning-header">
        <span class="material-symbols-outlined restore-warning-icon" aria-hidden="true">warning</span>
        <strong>This will overwrite the live database.</strong>
      </div>
      <ul class="restore-warning-list">
        <li>Every row currently in Postgres will be <strong>replaced</strong> with the contents of this backup — posts, accounts, DMs, follows, everything.</li>
        <li>Any user activity since the backup was taken will be <strong>permanently lost</strong>.</li>
        <li>All active sessions will break; users will be logged out mid-request.</li>
        <li>There is <strong>no undo</strong>. If this is the wrong backup, take a fresh one first.</li>
      </ul>
    </div>

    <div class="backup-meta">
      <div><span class="backup-meta-label">Backup:</span> <code>{restoreTarget.id}</code></div>
      <div><span class="backup-meta-label">Created:</span> {formatDate(restoreTarget.created_at)}</div>
      <div><span class="backup-meta-label">Size:</span> {formatSize(restoreTarget.file_size ?? restoreTarget.size)}</div>
    </div>

    <div class="form-group">
      <label class="field-label" for="restore-pass">Backup passphrase</label>
      <input
        id="restore-pass"
        type="password"
        class="input"
        bind:value={restorePassphrase}
        placeholder="The passphrase you used when creating this backup"
        autocomplete="off"
      />
    </div>

    <div class="form-group">
      <label class="field-label" for="restore-confirm">
        Type <code>RESTORE</code> to confirm
      </label>
      <input
        id="restore-confirm"
        type="text"
        class="input"
        bind:value={restoreConfirmation}
        placeholder="RESTORE"
        autocomplete="off"
      />
    </div>

    <div class="modal-actions">
      <button class="btn btn-ghost" type="button" onclick={() => (restoreModalOpen = false)}>
        Cancel
      </button>
      <button
        class="btn btn-danger"
        type="button"
        disabled={restoreSubmitting || restoreConfirmation !== 'RESTORE' || !restorePassphrase}
        onclick={handleRestore}
      >
        {restoreSubmitting ? 'Restoring…' : 'Restore database'}
      </button>
    </div>
  {/if}
</Modal>

<style>
  .backups-page {
    max-width: 800px;
  }

  .page-title {
    font-size: var(--text-2xl);
    font-weight: 700;
    margin-block-end: var(--space-6);
  }

  .section-title {
    font-size: var(--text-lg);
    font-weight: 600;
    margin-block-end: var(--space-2);
  }

  .section-desc {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    margin-block-end: var(--space-4);
  }

  .create-section {
    margin-block-end: var(--space-4);
  }

  .create-form {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    align-items: flex-start;
  }

  .passphrase-field {
    width: 100%;
    max-width: 400px;
  }

  .field-label {
    display: block;
    font-size: var(--text-sm);
    font-weight: 500;
    margin-block-end: var(--space-1);
  }

  .passphrase-input-row {
    display: flex;
    gap: var(--space-2);
  }

  .passphrase-input-row .input {
    flex: 1;
  }

  .backup-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .backup-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface);
    border-radius: var(--radius-md);
  }

  .backup-info {
    display: flex;
    align-items: center;
    gap: var(--space-4);
    font-size: var(--text-sm);
  }

  .backup-status {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    text-transform: capitalize;
  }

  .status-success {
    background: var(--color-success-soft);
    color: #166534;
  }

  .status-pending {
    background: var(--color-warning-soft);
    color: #92400e;
  }

  .status-failed {
    background: var(--color-danger-soft);
    color: #991b1b;
  }

  .backup-date {
    color: var(--color-text-secondary);
  }

  .backup-size {
    color: var(--color-text-tertiary);
    font-family: var(--font-mono);
    font-size: var(--text-xs);
  }

  .empty-text {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    text-align: center;
    padding: var(--space-6) 0;
  }

  .restore-warning {
    background: #fee2e2;
    border: 1px solid #fecaca;
    border-inline-start: 4px solid #dc2626;
    border-radius: var(--radius-md);
    padding: var(--space-4);
    margin-block-end: var(--space-4);
    color: #7f1d1d;
  }

  .restore-warning-header {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--text-base);
    margin-block-end: var(--space-2);
  }

  .restore-warning-icon {
    font-size: 22px;
    color: #dc2626;
    flex-shrink: 0;
  }

  .restore-warning-list {
    margin: 0;
    padding-inline-start: var(--space-5);
    font-size: var(--text-sm);
    line-height: 1.55;
  }

  .restore-warning-list li + li {
    margin-block-start: 4px;
  }

  .backup-meta {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    padding: var(--space-3);
    margin-block-end: var(--space-4);
    display: flex;
    flex-direction: column;
    gap: 2px;
    font-size: var(--text-sm);
  }

  .backup-meta-label {
    color: var(--color-text-tertiary);
    font-size: var(--text-xs);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    margin-inline-end: var(--space-2);
  }

  .form-group {
    margin-block-end: var(--space-3);
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
    margin-block-start: var(--space-4);
  }
</style>
