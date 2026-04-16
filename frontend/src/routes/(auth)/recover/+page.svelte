<script lang="ts">
  import { goto } from '$app/navigation';
  import { recoverAccount } from '$lib/api/recovery.js';

  let handle = $state('');
  let recoveryCode = $state('');
  let newPassword = $state('');
  let confirm = $state('');

  let submitting = $state(false);
  let error = $state('');
  let newCode = $state<string | null>(null);
  let savedChecked = $state(false);

  let canSubmit = $derived(
    handle.trim().length > 0 &&
      recoveryCode.trim().length > 0 &&
      newPassword.length >= 16 &&
      newPassword === confirm &&
      !submitting,
  );

  async function submit() {
    if (!canSubmit) return;
    submitting = true;
    error = '';
    try {
      const result = await recoverAccount({
        handle: handle.trim().replace(/^@/, ''),
        recovery_code: recoveryCode.trim(),
        new_password: newPassword,
        new_password_confirmation: confirm,
      });
      newCode = result.new_recovery_code;
    } catch (e: unknown) {
      const err = e as { body?: { error?: string } };
      error =
        err?.body?.error === 'auth.invalid_recovery'
          ? 'That handle and recovery code don\u2019t match anything we have on file.'
          : 'Recovery failed. Check your new password meets the minimum length (16 characters).';
    } finally {
      submitting = false;
    }
  }

  function copyCode() {
    if (newCode) navigator.clipboard?.writeText(newCode).catch(() => {});
  }

  function printPage() {
    window.print();
  }

  function finish() {
    goto('/login');
  }
</script>

<svelte:head>
  <title>Recover account</title>
</svelte:head>

<div class="recover-page">
  <header class="recover-header">
    <h1>Recover your account</h1>
    <p class="recover-sub">
      Use the recovery code you saved when you set up your account. This
      lets you set a new password without needing the email on file.
    </p>
  </header>

  {#if newCode}
    <div class="success">
      <div class="success-badge">Recovered</div>
      <h2>Here is your new recovery code</h2>
      <p class="success-sub">
        The code you just used has been retired. Save this one somewhere
        safe — we'll never show it again.
      </p>

      <div class="code-block">
        <code>{newCode}</code>
      </div>

      <div class="code-actions">
        <button type="button" class="btn btn-outline" onclick={copyCode}>Copy</button>
        <button type="button" class="btn btn-outline" onclick={printPage}>Print</button>
      </div>

      <label class="save-check">
        <input type="checkbox" bind:checked={savedChecked} />
        <span>I have saved this code somewhere safe.</span>
      </label>

      <button type="button" class="btn btn-primary" disabled={!savedChecked} onclick={finish}>
        Continue to sign in
      </button>
    </div>
  {:else}
    <form onsubmit={(e) => { e.preventDefault(); submit(); }} class="recover-form">
      <div class="field">
        <label for="r-handle">Account handle</label>
        <input
          id="r-handle"
          type="text"
          bind:value={handle}
          placeholder="e.g. ahmad"
          autocomplete="username"
          required
        />
      </div>

      <div class="field">
        <label for="r-code">Recovery code</label>
        <input
          id="r-code"
          type="text"
          bind:value={recoveryCode}
          placeholder="A7KQM-X9PN3-W4TDH-Y2FBC"
          autocomplete="one-time-code"
          spellcheck="false"
          required
        />
        <span class="hint">Case, spaces and extra dashes don't matter.</span>
      </div>

      <div class="field">
        <label for="r-pw">New password</label>
        <input
          id="r-pw"
          type="password"
          bind:value={newPassword}
          autocomplete="new-password"
          minlength="16"
          required
        />
        <span class="hint">Minimum 16 characters.</span>
      </div>

      <div class="field">
        <label for="r-pw2">Confirm new password</label>
        <input
          id="r-pw2"
          type="password"
          bind:value={confirm}
          autocomplete="new-password"
          required
        />
      </div>

      {#if error}
        <div class="error" role="alert">{error}</div>
      {/if}

      <button type="submit" class="btn btn-primary" disabled={!canSubmit}>
        {submitting ? 'Recovering\u2026' : 'Recover account'}
      </button>

      <p class="footer-note">
        No recovery code? Unfortunately that means this path can't help —
        recovery codes are cryptographically hashed and cannot be retrieved
        for you. Try <a href="/login">signing in</a> normally.
      </p>
    </form>
  {/if}
</div>

<style>
  .recover-page {
    max-width: 480px;
    margin: var(--space-10) auto;
    padding: 0 var(--space-4);
  }

  .recover-header h1 {
    font-size: var(--text-xl);
    font-weight: 700;
    margin: 0 0 var(--space-2) 0;
  }

  .recover-sub {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    line-height: 1.5;
    margin: 0 0 var(--space-6) 0;
  }

  .recover-form {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }

  .field label {
    font-weight: 600;
    color: var(--color-text);
  }

  .field input {
    padding: var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface);
    color: var(--color-text);
    font: inherit;
    font-family: var(--font-mono, monospace);
  }

  #r-handle,
  #r-pw,
  #r-pw2 {
    font-family: inherit;
  }

  .hint {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .error {
    background: var(--color-danger-surface, #fee);
    color: var(--color-danger, #b00);
    border: 1px solid var(--color-danger, #b00);
    border-radius: var(--radius-md);
    padding: var(--space-3);
    font-size: var(--text-sm);
  }

  .footer-note {
    color: var(--color-text-tertiary);
    font-size: var(--text-xs);
    line-height: 1.5;
    margin-block-start: var(--space-4);
  }

  .success {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .success-badge {
    display: inline-block;
    align-self: flex-start;
    background: var(--color-success, #16a34a);
    color: white;
    font-size: var(--text-xs);
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding: 2px 10px;
    border-radius: 9999px;
  }

  .success h2 {
    font-size: var(--text-lg);
    margin: 0;
  }

  .success-sub {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    line-height: 1.5;
    margin: 0;
  }

  .code-block {
    background: var(--color-surface-alt, rgba(0, 0, 0, 0.04));
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    padding: var(--space-5) var(--space-4);
    text-align: center;
  }

  .code-block code {
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 1.35rem;
    letter-spacing: 0.08em;
    font-weight: 700;
    color: var(--color-text);
    word-break: break-all;
  }

  .code-actions {
    display: flex;
    gap: var(--space-2);
  }

  .save-check {
    display: flex;
    align-items: flex-start;
    gap: var(--space-2);
    font-size: var(--text-sm);
    color: var(--color-text);
    margin-block-start: var(--space-2);
  }

  @media print {
    .recover-form,
    .code-actions,
    .save-check,
    .footer-note {
      display: none;
    }
  }
</style>
