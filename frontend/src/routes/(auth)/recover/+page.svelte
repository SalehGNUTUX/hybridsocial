<script lang="ts">
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client.js';
  import { solvePow, type PowChallenge, type PowSolution } from '$lib/utils/pow.js';
  import { validateRecovery, completeRecovery } from '$lib/api/recovery.js';
  import Captcha from '$lib/components/auth/Captcha.svelte';

  type Step = 'verify' | 'reset' | 'done';

  // Step 1 — verify identity
  let handle = $state('');
  let currentEmail = $state('');
  let recoveryCode = $state('');
  let otpCode = $state('');

  // PoW
  let powSolution = $state<PowSolution | null>(null);
  let powSolving = $state(false);

  // Captcha (provider selected by the admin: turnstile | hcaptcha | recaptcha)
  let captchaProvider = $state('none');
  let captchaSiteKey = $state('');
  let captchaToken = $state('');
  let captcha: { getToken: () => Promise<string> } | undefined = $state();
  let captchaWidget = $derived(
    captchaProvider === 'turnstile' || captchaProvider === 'hcaptcha'
  );

  // Step 2 — reset
  let recoveryToken = $state<string | null>(null);
  let newEmail = $state('');
  let newPassword = $state('');
  let confirm = $state('');

  // Step 3 — done
  let newCode = $state<string | null>(null);
  let savedChecked = $state(false);

  // Shared
  let step = $state<Step>('verify');
  let submitting = $state(false);
  let error = $state('');

  let canVerify = $derived(
    handle.trim().length > 0 &&
      currentEmail.trim().length > 0 &&
      recoveryCode.trim().length > 0 &&
      otpCode.trim().length >= 6 &&
      (!captchaWidget || captchaToken.length > 0) &&
      !powSolving &&
      !submitting,
  );

  let canReset = $derived(
    newEmail.trim().length > 0 &&
      newPassword.length >= 16 &&
      newPassword === confirm &&
      !submitting,
  );

  async function loadPow() {
    try {
      powSolving = true;
      const challenge = await api.get<PowChallenge>('/api/v1/auth/pow-challenge');
      powSolution = await solvePow(challenge);
    } catch {
      powSolution = null;
    } finally {
      powSolving = false;
    }
  }

  async function checkCaptcha() {
    try {
      const info = await api.get<{
        captcha_provider?: string;
        captcha_site_key?: string;
      }>('/api/v1/instance/info');
      if (info.captcha_provider && info.captcha_provider !== 'none' && info.captcha_site_key) {
        captchaProvider = info.captcha_provider;
        captchaSiteKey = info.captcha_site_key;
      }
    } catch {
      // No-op — treat as disabled
    }
  }

  // Kick off on mount
  loadPow();
  checkCaptcha();

  async function submitVerify() {
    if (!canVerify) return;
    submitting = true;
    error = '';

    try {
      const payload: {
        handle: string;
        recovery_code: string;
        otp_code: string;
        current_email: string;
        pow_prefix?: string;
        pow_nonce?: string;
        captcha_token?: string;
      } = {
        handle: handle.trim().replace(/^@/, ''),
        recovery_code: recoveryCode.trim(),
        otp_code: otpCode.trim().replace(/\s/g, ''),
        current_email: currentEmail.trim(),
      };
      if (powSolution) {
        payload.pow_prefix = powSolution.challenge;
        payload.pow_nonce = String(powSolution.nonce);
      }
      if (captchaProvider !== 'none' && captcha) {
        payload.captcha_token = await captcha.getToken();
      }

      const res = await validateRecovery(payload);
      recoveryToken = res.recovery_token;
      step = 'reset';
    } catch (e: unknown) {
      const err = e as { body?: { error?: string } };
      error =
        err?.body?.error === 'auth.invalid_recovery'
          ? "We couldn't verify those details. Your handle, recovery code, 6-digit authenticator code, and current email must all match."
          : err?.body?.error === 'auth.pow_required'
            ? 'Please wait while we generate a proof-of-work challenge and try again.'
            : err?.body?.error === 'auth.captcha_failed'
              ? 'Captcha verification failed. Try again.'
              : 'Verification failed. Please try again.';
      // Refresh PoW since the one we sent is consumed
      loadPow();
    } finally {
      submitting = false;
    }
  }

  async function submitReset() {
    if (!canReset || !recoveryToken) return;
    submitting = true;
    error = '';

    try {
      const res = await completeRecovery({
        recovery_token: recoveryToken,
        new_email: newEmail.trim(),
        new_password: newPassword,
        new_password_confirmation: confirm,
      });
      newCode = res.new_recovery_code;
      step = 'done';
    } catch (e: unknown) {
      const err = e as { body?: { error?: string } };
      if (err?.body?.error === 'recovery.token_expired') {
        error = 'Your verification expired. Please start over.';
        step = 'verify';
        recoveryToken = null;
      } else if (err?.body?.error === 'recovery.token_invalid') {
        error = "We couldn't verify that session. Please start over.";
        step = 'verify';
        recoveryToken = null;
      } else {
        error =
          'Failed to apply changes. Check your new email is valid and your password is at least 16 characters.';
      }
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
      Use the recovery code you saved when you set up your account.
      Recovery is a two-step flow: first we verify your identity,
      then you set a new email and password. On success we revoke
      all sessions and issue a fresh recovery code.
    </p>
  </header>

  <ol class="recover-steps" aria-label="Recovery steps">
    <li class:active={step === 'verify'} class:done={step !== 'verify'}>
      1. Verify identity
    </li>
    <li
      class:active={step === 'reset'}
      class:done={step === 'done'}
      class:pending={step === 'verify'}
    >
      2. Reset email & password
    </li>
  </ol>

  {#if step === 'done' && newCode}
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
  {:else if step === 'reset'}
    <form
      onsubmit={(e) => {
        e.preventDefault();
        submitReset();
      }}
      class="recover-form"
    >
      <p class="step-sub">
        Identity verified. Choose your new email and password. We'll
        also revoke any active sessions and issue a fresh recovery
        code on the next screen.
      </p>

      <div class="field">
        <label for="r-new-email">New email</label>
        <input
          id="r-new-email"
          type="email"
          bind:value={newEmail}
          placeholder="you@example.com"
          autocomplete="email"
          required
        />
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

      <button type="submit" class="btn btn-primary" disabled={!canReset}>
        {submitting ? 'Applying\u2026' : 'Reset email & password'}
      </button>
    </form>
  {:else}
    <form
      onsubmit={(e) => {
        e.preventDefault();
        submitVerify();
      }}
      class="recover-form"
    >
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
        <label for="r-email">Current email on file</label>
        <input
          id="r-email"
          type="email"
          bind:value={currentEmail}
          placeholder="you@example.com"
          autocomplete="email"
          required
        />
        <span class="hint">
          The email address currently registered on the account.
        </span>
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
        <label for="r-otp">Authenticator code</label>
        <input
          id="r-otp"
          type="text"
          bind:value={otpCode}
          placeholder="123456"
          inputmode="numeric"
          autocomplete="one-time-code"
          maxlength="8"
          spellcheck="false"
          required
        />
        <span class="hint">
          The 6-digit code from the authenticator app you set up with 2FA.
        </span>
      </div>

      {#if captchaProvider !== 'none' && captchaSiteKey}
        <div class="turnstile-wrap">
          <Captcha
            bind:this={captcha}
            provider={captchaProvider}
            siteKey={captchaSiteKey}
            bind:token={captchaToken}
            action="recover"
          />
        </div>
      {/if}

      {#if powSolving}
        <p class="pow-status">Generating proof-of-work challenge&hellip;</p>
      {/if}

      {#if error}
        <div class="error" role="alert">{error}</div>
      {/if}

      <button type="submit" class="btn btn-primary" disabled={!canVerify}>
        {submitting ? 'Verifying\u2026' : 'Verify identity'}
      </button>

      <p class="footer-note">
        No recovery code, or no authenticator app? Unfortunately this
        path can't help — recovery codes are cryptographically hashed
        and 2FA is required. Try <a href="/login">signing in</a>
        normally or <a href="/login?reset=1">reset your password via
        email</a>.
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
    margin: 0 0 var(--space-4) 0;
  }

  .recover-steps {
    display: flex;
    list-style: none;
    padding: 0;
    margin: 0 0 var(--space-6) 0;
    gap: var(--space-2);
    counter-reset: step;
  }

  .recover-steps li {
    flex: 1;
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
    text-align: center;
  }

  .recover-steps li.active {
    border-color: var(--color-primary);
    color: var(--color-primary);
    font-weight: 700;
  }

  .recover-steps li.done {
    border-color: var(--color-success, #16a34a);
    color: var(--color-success, #16a34a);
  }

  .recover-form {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .step-sub {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    line-height: 1.5;
    margin: 0;
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
  #r-email,
  #r-new-email,
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

  .pow-status {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
    margin: 0;
  }

  .turnstile-wrap {
    display: flex;
    justify-content: center;
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
    .footer-note,
    .recover-steps {
      display: none;
    }
  }
</style>
