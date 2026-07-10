<script lang="ts">
  import { onMount } from 'svelte';
  import { get } from 'svelte/store';
  import { changePassword, setupTwoFactor, verifyTwoFactor, disableTwoFactor, getCurrentUser } from '$lib/api/auth.js';
  import type { TwoFactorSetup } from '$lib/api/types.js';
  import { authStore, setUser } from '$lib/stores/auth.js';
  import { addToast } from '$lib/stores/toast.js';
  import { instanceName } from '$lib/stores/instance.js';
  import Spinner from '$lib/components/ui/Spinner.svelte';
  import Modal from '$lib/components/ui/Modal.svelte';
  import QRCode from 'qrcode';

  import { api } from '$lib/api/client.js';
  import {
    getRecoveryCodeStatus,
    generateRecoveryCode,
    deleteRecoveryCode,
  } from '$lib/api/recovery.js';
  import {
    isWarningDisabled,
    setWarningDisabled,
    clearTrustedDomains,
    knownTrustedDomains,
  } from '$lib/utils/external-link-trust.js';

  // The built-in allowlist is static — read once at module load so the
  // template doesn't recompute it every render.
  const preTrusted = knownTrustedDomains();
  let showPreTrusted = $state(false);

  // --- External link warning ---
  let externalLinkWarningEnabled = $state(true);

  function toggleExternalLinkWarning() {
    externalLinkWarningEnabled = !externalLinkWarningEnabled;
    setWarningDisabled(!externalLinkWarningEnabled);
  }

  function clearTrustedSites() {
    clearTrustedDomains();
    addToast('Trusted sites cleared', 'success');
  }

  // --- Recovery code ---
  let recoveryStatus = $state<{
    enabled: boolean;
    generated_at: string | null;
    last_used_at: string | null;
  } | null>(null);
  let recoveryPassword = $state('');
  let recoveryGenerating = $state(false);
  let recoveryClearing = $state(false);
  let recoveryNewCode = $state<string | null>(null);
  let recoveryError = $state('');

  async function loadRecoveryStatus() {
    try {
      recoveryStatus = await getRecoveryCodeStatus();
    } catch {
      recoveryStatus = { enabled: false, generated_at: null, last_used_at: null };
    }
  }

  async function handleGenerateRecovery() {
    if (!recoveryPassword) {
      recoveryError = 'Enter your current password to continue.';
      return;
    }
    recoveryGenerating = true;
    recoveryError = '';
    try {
      const result = await generateRecoveryCode(recoveryPassword);
      recoveryNewCode = result.recovery_code;
      recoveryPassword = '';
      await loadRecoveryStatus();
    } catch (e: unknown) {
      const err = e as { body?: { error?: string; message?: string } };
      recoveryError =
        err?.body?.error === 'auth.invalid_password'
          ? 'That password didn\u2019t match.'
          : err?.body?.error === 'recovery.two_factor_required'
            ? err?.body?.message ||
              'Enable two-factor authentication before generating a recovery code.'
            : 'Failed to generate a code.';
    } finally {
      recoveryGenerating = false;
    }
  }

  async function handleClearRecovery() {
    if (!recoveryPassword) {
      recoveryError = 'Enter your current password to clear the code.';
      return;
    }
    recoveryClearing = true;
    recoveryError = '';
    try {
      await deleteRecoveryCode(recoveryPassword);
      recoveryPassword = '';
      recoveryNewCode = null;
      await loadRecoveryStatus();
    } catch (e: unknown) {
      const err = e as { body?: { error?: string } };
      recoveryError =
        err?.body?.error === 'auth.invalid_password'
          ? 'That password didn\u2019t match.'
          : 'Failed to clear the code.';
    } finally {
      recoveryClearing = false;
    }
  }

  function copyRecoveryCode() {
    if (recoveryNewCode) navigator.clipboard?.writeText(recoveryNewCode).catch(() => {});
    addToast('Copied', 'success');
  }

  function dismissNewCode() {
    recoveryNewCode = null;
  }

  // WebAuthn / Security Keys
  interface WebauthnCred { id: string; name: string; credential_id: string; sign_count: number; last_used_at: string | null; created_at: string; }
  let securityKeys = $state<WebauthnCred[]>([]);
  let keysLoading = $state(true);
  let keyName = $state('');
  let keyRegistering = $state(false);

  async function loadKeys() {
    try {
      securityKeys = await api.get<WebauthnCred[]>('/api/v1/auth/webauthn/credentials');
    } catch {
      addToast('Could not load your security keys', 'error');
    }
    finally { keysLoading = false; }
  }

  async function registerKey() {
    if (!navigator.credentials) {
      addToast('WebAuthn not supported in this browser', 'error');
      return;
    }
    keyRegistering = true;
    try {
      // 1. Get challenge from server
      const options = await api.post<any>('/api/v1/auth/webauthn/register/challenge');

      // 2. Convert challenge and user.id to ArrayBuffer
      const publicKey = {
        challenge: Uint8Array.from(atob(options.challenge.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0)),
        rp: options.rp,
        user: {
          id: Uint8Array.from(atob(options.user.id.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0)),
          name: options.user.name,
          displayName: options.user.displayName,
        },
        pubKeyCredParams: options.pubKeyCredParams,
        timeout: options.timeout,
        attestation: options.attestation as AttestationConveyancePreference,
        authenticatorSelection: options.authenticatorSelection,
      };

      // 3. Create credential via browser
      const credential = await navigator.credentials.create({ publicKey }) as PublicKeyCredential;
      if (!credential) throw new Error('No credential returned');

      const response = credential.response as AuthenticatorAttestationResponse;

      // 4. Send to server
      await api.post('/api/v1/auth/webauthn/register/verify', {
        credential_id: btoa(String.fromCharCode(...new Uint8Array(credential.rawId))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, ''),
        public_key: btoa(String.fromCharCode(...new Uint8Array(response.getPublicKey?.() || new ArrayBuffer(0)))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, ''),
        name: keyName || 'Security Key',
        response: {
          attestationObject: btoa(String.fromCharCode(...new Uint8Array(response.attestationObject))),
          clientDataJSON: btoa(String.fromCharCode(...new Uint8Array(response.clientDataJSON))),
        }
      });

      keyName = '';
      addToast('Security key registered', 'success');
      await loadKeys();
    } catch (e) {
      addToast(e instanceof Error ? e.message : 'Failed to register key', 'error');
    } finally { keyRegistering = false; }
  }

  // Removing a security key removes an authentication factor, so confirm
  // it explicitly rather than deleting on a single click.
  let keyToDelete = $state<WebauthnCred | null>(null);
  let showDeleteKeyModal = $state(false);
  let keyDeleting = $state(false);

  function askDeleteKey(key: WebauthnCred) {
    keyToDelete = key;
    showDeleteKeyModal = true;
  }

  async function confirmDeleteKey() {
    if (!keyToDelete || keyDeleting) return;
    keyDeleting = true;
    const id = keyToDelete.id;
    try {
      await api.delete(`/api/v1/auth/webauthn/credentials/${id}`);
      securityKeys = securityKeys.filter(k => k.id !== id);
      addToast('Security key removed', 'success');
      showDeleteKeyModal = false;
      keyToDelete = null;
    } catch {
      addToast('Failed to remove key', 'error');
    } finally {
      keyDeleting = false;
    }
  }

  // Password change
  let currentPassword = $state('');
  let newPassword = $state('');
  let confirmPassword = $state('');
  let passwordSaving = $state(false);
  let passwordSaved = $state(false);
  let passwordError: string | null = $state(null);

  // 2FA — load from user state
  let twoFactorEnabled = $state(false);

  onMount(async () => {
    const state = get(authStore);
    twoFactorEnabled = !!(state.user as any)?.two_factor_enabled;
    externalLinkWarningEnabled = !isWarningDisabled();
    loadKeys();
    loadRecoveryStatus();
  });

  let twoFactorSetup: TwoFactorSetup | null = $state(null);
  let verifyCode = $state('');
  let disableCode = $state('');
  let twoFALoading = $state(false);
  let twoFAError: string | null = $state(null);
  let twoFASuccess: string | null = $state(null);
  let showSetup = $state(false);
  let showDisable = $state(false);
  let qrDataUrl = $state('');

  async function handlePasswordChange() {
    passwordError = null;
    passwordSaved = false;

    if (newPassword !== confirmPassword) {
      passwordError = 'New passwords do not match';
      return;
    }

    if (newPassword.length < 16) {
      passwordError = 'Password must be at least 16 characters';
      return;
    }

    passwordSaving = true;
    try {
      await changePassword(currentPassword, newPassword);
      passwordSaved = true;
      currentPassword = '';
      newPassword = '';
      confirmPassword = '';
      setTimeout(() => { passwordSaved = false; }, 3000);
    } catch (e) {
      passwordError = e instanceof Error ? e.message : 'Failed to change password';
    } finally {
      passwordSaving = false;
    }
  }

  async function handleSetup2FA() {
    twoFAError = null;
    twoFALoading = true;
    try {
      twoFactorSetup = await setupTwoFactor();
      // Generate QR code from the otpauth URI
      if (twoFactorSetup.uri) {
        qrDataUrl = await QRCode.toDataURL(twoFactorSetup.uri, { width: 200, margin: 2 });
      }
      showSetup = true;
    } catch (e) {
      twoFAError = e instanceof Error ? e.message : 'Failed to setup 2FA';
    } finally {
      twoFALoading = false;
    }
  }

  async function handleVerify2FA() {
    twoFAError = null;
    twoFALoading = true;
    try {
      await verifyTwoFactor(verifyCode);
      twoFactorEnabled = true;
      showSetup = false;
      twoFactorSetup = null;
      verifyCode = '';
      twoFASuccess = 'Two-factor authentication enabled';
      setTimeout(() => { twoFASuccess = null; }, 3000);
      // Refresh user data so admin panel sees 2FA enabled
      try {
        const user = await getCurrentUser();
        setUser(user);
      } catch {};
    } catch (e) {
      twoFAError = e instanceof Error ? e.message : 'Invalid verification code';
    } finally {
      twoFALoading = false;
    }
  }

  async function handleDisable2FA() {
    twoFAError = null;
    twoFALoading = true;
    try {
      await disableTwoFactor(disableCode);
      twoFactorEnabled = false;
      showDisable = false;
      disableCode = '';
      twoFASuccess = 'Two-factor authentication disabled';
      setTimeout(() => { twoFASuccess = null; }, 3000);
    } catch (e) {
      twoFAError = e instanceof Error ? e.message : 'Invalid code';
    } finally {
      twoFALoading = false;
    }
  }
</script>

<div class="stitch-settings">
  <!-- Change Password -->
  <section class="stitch-section">
    <div class="stitch-section-heading">
      <span class="stitch-section-icon" aria-hidden="true">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>
        </svg>
      </span>
      <h2 class="stitch-section-title">Change Password</h2>
    </div>

    <div class="stitch-section-content">
      <form class="stitch-form" onsubmit={(e) => { e.preventDefault(); handlePasswordChange(); }}>
        <div class="stitch-field">
          <label class="stitch-label" for="current-password">CURRENT PASSWORD</label>
          <input
            id="current-password"
            type="password"
            class="stitch-input"
            bind:value={currentPassword}
            autocomplete="current-password"
            required
          />
        </div>

        <div class="stitch-field">
          <label class="stitch-label" for="new-password">NEW PASSWORD</label>
          <input
            id="new-password"
            type="password"
            class="stitch-input"
            bind:value={newPassword}
            autocomplete="new-password"
            minlength="16"
            placeholder="At least 16 characters"
            required
          />
        </div>

        <div class="stitch-field">
          <label class="stitch-label" for="confirm-password">CONFIRM NEW PASSWORD</label>
          <input
            id="confirm-password"
            type="password"
            class="stitch-input"
            bind:value={confirmPassword}
            autocomplete="new-password"
            required
          />
        </div>

        {#if passwordError}
          <div class="stitch-error">{passwordError}</div>
        {/if}

        {#if passwordSaved}
          <div class="stitch-success">Password changed successfully</div>
        {/if}

        <div class="stitch-actions">
          <button class="stitch-btn-primary" type="submit" disabled={passwordSaving}>
            {#if passwordSaving}
              <Spinner size={16} color="#fff" />
            {/if}
            Change Password
          </button>
        </div>
      </form>
    </div>
  </section>

  <!-- Two-Factor Authentication -->
  <section class="stitch-section">
    <div class="stitch-section-heading">
      <span class="stitch-section-icon" aria-hidden="true">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
        </svg>
      </span>
      <h2 class="stitch-section-title">Two-Factor Authentication</h2>
    </div>

    <div class="stitch-section-content">
      <div class="stitch-form">
        {#if twoFASuccess}
          <div class="stitch-success">{twoFASuccess}</div>
        {/if}

        {#if twoFAError}
          <div class="stitch-error">{twoFAError}</div>
        {/if}

        {#if !twoFactorEnabled && !showSetup}
          <p class="stitch-description">
            Add an extra layer of security to your account by enabling two-factor authentication.
          </p>
          <div class="stitch-actions">
            <button class="stitch-btn-outline" type="button" onclick={handleSetup2FA} disabled={twoFALoading}>
              {#if twoFALoading}
                <Spinner size={16} />
              {/if}
              Enable 2FA
            </button>
          </div>
        {:else if showSetup && twoFactorSetup}
          <p class="stitch-description">
            Scan the QR code below with your authenticator app (like Google Authenticator or Authy), then enter the verification code.
          </p>

          <div class="stitch-qr">
            <img src={qrDataUrl} alt="2FA QR Code" class="stitch-qr-img" />
          </div>

          <div class="stitch-secret">
            <span class="stitch-label">MANUAL ENTRY KEY</span>
            <code class="stitch-secret-code">{twoFactorSetup.secret}</code>
          </div>

          {#if twoFactorSetup.backup_codes?.length > 0}
            <div class="stitch-backup">
              <span class="stitch-label">BACKUP CODES (SAVE THESE SOMEWHERE SAFE)</span>
              <div class="stitch-codes-grid">
                {#each twoFactorSetup.backup_codes as code}
                  <code class="stitch-backup-code">{code}</code>
                {/each}
              </div>
            </div>
          {/if}

          <form onsubmit={(e) => { e.preventDefault(); handleVerify2FA(); }}>
            <div class="stitch-field">
              <label class="stitch-label" for="verify-code">VERIFICATION CODE</label>
              <input
                id="verify-code"
                type="text"
                class="stitch-input"
                bind:value={verifyCode}
                placeholder="Enter 6-digit code"
                maxlength="6"
                autocomplete="one-time-code"
                required
              />
            </div>
            <div class="stitch-actions" style="margin-block-start: 16px;">
              <button class="stitch-btn-ghost" type="button" onclick={() => { showSetup = false; twoFactorSetup = null; }}>
                Cancel
              </button>
              <button class="stitch-btn-primary" type="submit" disabled={twoFALoading}>
                {#if twoFALoading}
                  <Spinner size={16} color="#fff" />
                {/if}
                Verify & Enable
              </button>
            </div>
          </form>
        {:else if twoFactorEnabled && !showDisable}
          <div class="stitch-status-row">
            <div class="stitch-status-info">
              <span class="stitch-status-label">Two-factor authentication</span>
              <span class="stitch-status-value stitch-status-enabled">Enabled</span>
            </div>
            <button class="stitch-btn-danger" type="button" onclick={() => { showDisable = true; }}>
              Disable 2FA
            </button>
          </div>
        {:else if showDisable}
          <form onsubmit={(e) => { e.preventDefault(); handleDisable2FA(); }}>
            <div class="stitch-field">
              <label class="stitch-label" for="disable-code">ENTER YOUR 2FA CODE TO DISABLE</label>
              <input
                id="disable-code"
                type="text"
                class="stitch-input"
                bind:value={disableCode}
                placeholder="Enter 6-digit code"
                maxlength="6"
                autocomplete="one-time-code"
                required
              />
            </div>
            <div class="stitch-actions" style="margin-block-start: 16px;">
              <button class="stitch-btn-ghost" type="button" onclick={() => { showDisable = false; }}>
                Cancel
              </button>
              <button class="stitch-btn-danger" type="submit" disabled={twoFALoading}>
                {#if twoFALoading}
                  <Spinner size={16} color="#fff" />
                {/if}
                Disable 2FA
              </button>
            </div>
          </form>
        {/if}
      </div>
    </div>
  </section>

  <!-- Security Keys (WebAuthn/FIDO2) -->
  <section class="stitch-section">
    <div class="stitch-section-heading">
      <span class="stitch-section-icon" aria-hidden="true">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 11-7.778 7.778 5.5 5.5 0 017.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/>
        </svg>
      </span>
      <div>
        <h2 class="stitch-section-title">Security Keys</h2>
        <p class="stitch-section-desc">Use a hardware security key, biometric, or passkey (e.g. YubiKey, Bitwarden, Touch ID) for secure login.</p>
      </div>
    </div>
    <div class="stitch-section-content">
      {#if keysLoading}
        <div style="padding: 16px; text-align: center"><Spinner /></div>
      {:else}
        {#if securityKeys.length > 0}
          <div class="keys-list">
            {#each securityKeys as key (key.id)}
              <div class="key-item">
                <div class="key-info">
                  <span class="material-symbols-outlined key-icon">key</span>
                  <div>
                    <span class="key-name">{key.name}</span>
                    <span class="key-meta">
                      Added {new Date(key.created_at).toLocaleDateString()}
                      {#if key.last_used_at}
                         &middot; Last used {new Date(key.last_used_at).toLocaleDateString()}
                      {/if}
                      &middot; Used {key.sign_count} times
                    </span>
                  </div>
                </div>
                <button type="button" class="key-remove" onclick={() => askDeleteKey(key)} aria-label="Remove {key.name}">
                  <span class="material-symbols-outlined" style="font-size: 18px">delete</span>
                </button>
              </div>
            {/each}
          </div>
        {/if}

        <div class="key-add-form">
          <input type="text" class="key-name-input" bind:value={keyName} placeholder="Key name (e.g. YubiKey, Bitwarden)" />
          <button type="button" class="key-add-btn" onclick={registerKey} disabled={keyRegistering}>
            <span class="material-symbols-outlined" style="font-size: 18px">add</span>
            {keyRegistering ? 'Waiting for key...' : 'Add Security Key'}
          </button>
        </div>
      {/if}
    </div>
  </section>

  <!-- Account recovery code -->
  <section class="stitch-section">
    <div class="stitch-section-heading">
      <span class="stitch-section-icon" aria-hidden="true">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/>
        </svg>
      </span>
      <div>
        <h2 class="stitch-section-title">Account recovery code</h2>
        <p class="stitch-section-desc">
          A backup you can use to reset your password if you ever lose access to
          your email. Keep it somewhere safe — we can't retrieve it for you.
        </p>
      </div>
    </div>

    <div class="stitch-section-body">
      {#if recoveryNewCode}
        <div class="recovery-reveal">
          <div class="recovery-reveal-title">Save your new recovery code</div>
          <p class="recovery-reveal-sub">
            This is the only time we'll show it. If you lose this and your email,
            your account can't be recovered.
          </p>
          <div class="recovery-code-display">
            <code>{recoveryNewCode}</code>
          </div>
          <div class="recovery-actions">
            <button type="button" class="btn btn-outline" onclick={copyRecoveryCode}>Copy</button>
            <button type="button" class="btn btn-outline" onclick={() => window.print()}>Print</button>
            <button type="button" class="btn btn-primary" onclick={dismissNewCode}>I saved it</button>
          </div>
        </div>
      {:else if !twoFactorEnabled}
        <div class="recovery-state off">
          <strong>Enable two-factor authentication first.</strong>
          <span class="recovery-state-meta">
            Recovery codes are only useful as a second factor — if
            anyone with just your password could use one, the code
            would be a downgrade, not a recovery path. Turn on 2FA
            above and the generator will unlock here.
          </span>
        </div>
      {:else}
        <div class="recovery-status">
          {#if recoveryStatus?.enabled}
            <div class="recovery-state on">
              <strong>Recovery code is set.</strong>
              {#if recoveryStatus.generated_at}
                <span class="recovery-state-meta">
                  Last regenerated {new Date(recoveryStatus.generated_at).toLocaleDateString()}
                </span>
              {/if}
              {#if recoveryStatus.last_used_at}
                <span class="recovery-state-meta">
                  Last used {new Date(recoveryStatus.last_used_at).toLocaleDateString()}
                </span>
              {/if}
            </div>
          {:else}
            <div class="recovery-state off">
              <strong>No recovery code set.</strong>
              <span class="recovery-state-meta">
                Optional. If you lose email access and your password, you'll
                have no way back into the account without one.
              </span>
            </div>
          {/if}

          <div class="recovery-form">
            <label for="rc-password">Current password</label>
            <input
              id="rc-password"
              type="password"
              bind:value={recoveryPassword}
              autocomplete="current-password"
              placeholder="Enter to confirm"
            />

            {#if recoveryError}
              <div class="recovery-error" role="alert">{recoveryError}</div>
            {/if}

            <div class="recovery-actions">
              <button
                type="button"
                class="btn btn-primary"
                disabled={recoveryGenerating || !recoveryPassword}
                onclick={handleGenerateRecovery}
              >
                {recoveryGenerating
                  ? 'Generating\u2026'
                  : recoveryStatus?.enabled
                    ? 'Generate new code'
                    : 'Generate recovery code'}
              </button>

              {#if recoveryStatus?.enabled}
                <button
                  type="button"
                  class="btn btn-ghost-danger"
                  disabled={recoveryClearing || !recoveryPassword}
                  onclick={handleClearRecovery}
                >
                  {recoveryClearing ? 'Clearing\u2026' : 'Remove code'}
                </button>
              {/if}
            </div>
          </div>
        </div>
      {/if}
    </div>
  </section>

  <!-- External link warning -->
  <section class="stitch-section">
    <div class="stitch-section-heading">
      <span class="stitch-section-icon" aria-hidden="true">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
          <polyline points="15 3 21 3 21 9" />
          <line x1="10" y1="14" x2="21" y2="3" />
        </svg>
      </span>
      <div>
        <h2 class="stitch-section-title">External link warning</h2>
        <p class="stitch-section-desc">
          Pop a confirmation dialog before opening links that lead off
          {$instanceName}. Helps catch typosquatted phishing domains
          before you visit them.
        </p>
      </div>
    </div>

    <div class="stitch-section-body">
      <div class="ext-link-row">
        <div class="ext-link-info">
          <span class="ext-link-label">Warn before opening external links</span>
          <span class="ext-link-meta">
            {externalLinkWarningEnabled
              ? 'On — every off-site link prompts before navigating.'
              : 'Off — links open immediately. Re-enable any time.'}
          </span>
        </div>
        <button
          type="button"
          class="ext-link-toggle"
          class:on={externalLinkWarningEnabled}
          aria-pressed={externalLinkWarningEnabled}
          aria-label="Toggle external link warning"
          onclick={toggleExternalLinkWarning}
        >
          <span class="ext-link-knob"></span>
        </button>
      </div>

      {#if externalLinkWarningEnabled}
        <div class="ext-link-row" style="margin-block-start: 12px;">
          <div class="ext-link-info">
            <span class="ext-link-label">Trusted sites</span>
            <span class="ext-link-meta">
              Sites you've checked "Don't warn me again" for. Entries
              expire after 24 hours automatically.
            </span>
          </div>
          <button
            type="button"
            class="btn btn-ghost-danger"
            onclick={clearTrustedSites}
          >
            Clear all
          </button>
        </div>

        <div class="ext-link-row" style="margin-block-start: 12px;">
          <div class="ext-link-info">
            <span class="ext-link-label">Pre-trusted well-known sites</span>
            <span class="ext-link-meta">
              We skip the warning for major platforms ({preTrusted.length} domains
              like GitHub, Wikipedia, YouTube). Subdomains are covered too.
            </span>
          </div>
          <button
            type="button"
            class="btn btn-ghost"
            onclick={() => (showPreTrusted = !showPreTrusted)}
          >
            {showPreTrusted ? 'Hide' : 'Show list'}
          </button>
        </div>

        {#if showPreTrusted}
          <ul class="pre-trusted-list">
            {#each preTrusted as domain (domain)}
              <li class="pre-trusted-item"><code>{domain}</code></li>
            {/each}
          </ul>
        {/if}
      {/if}
    </div>
  </section>

</div>

<Modal bind:open={showDeleteKeyModal} title="Remove this security key?" onclose={() => { keyToDelete = null; }}>
  {#if keyToDelete}
    <p class="confirm-message">
      <strong>{keyToDelete.name}</strong> will no longer be able to sign in to your account. Make sure you have another way to log in before removing it.
    </p>
    <div class="confirm-actions">
      <button type="button" class="stitch-btn-ghost" onclick={() => (showDeleteKeyModal = false)}>Cancel</button>
      <button type="button" class="stitch-btn-danger" onclick={confirmDeleteKey} disabled={keyDeleting}>
        {#if keyDeleting}<Spinner size={14} color="#fff" />{/if}
        Remove key
      </button>
    </div>
  {/if}
</Modal>

<style>
  /* ---- Recovery code ---- */
  .recovery-reveal {
    background: var(--color-warning-surface, rgba(217, 119, 6, 0.08));
    border: 1px solid var(--color-warning, #d97706);
    border-radius: var(--radius-lg);
    padding: var(--space-4);
  }

  .recovery-reveal-title {
    font-weight: 700;
    color: var(--color-text);
    margin-block-end: var(--space-2);
  }

  .recovery-reveal-sub {
    font-size: var(--text-sm);
    color: var(--color-text);
    line-height: 1.5;
    margin: 0 0 var(--space-3) 0;
  }

  .recovery-code-display {
    background: var(--color-surface-raised, #fff);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    padding: var(--space-4);
    text-align: center;
    margin-block-end: var(--space-3);
  }

  .recovery-code-display code {
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 1.35rem;
    font-weight: 700;
    letter-spacing: 0.08em;
    color: var(--color-text);
    word-break: break-all;
  }

  .recovery-state {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
    margin-block-end: var(--space-4);
    font-size: var(--text-sm);
    color: var(--color-text);
  }

  .recovery-state-meta {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .recovery-form {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .recovery-form label {
    font-weight: 600;
    font-size: var(--text-sm);
  }

  .recovery-form input {
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface);
    color: var(--color-text);
    font: inherit;
  }

  .recovery-actions {
    display: flex;
    gap: var(--space-2);
    flex-wrap: wrap;
  }

  .recovery-error {
    color: var(--color-danger, #b00);
    font-size: var(--text-sm);
  }

  /* ---- External link warning ---- */
  .ext-link-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-4);
    padding: var(--space-3) 0;
  }

  .ext-link-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    flex: 1;
  }

  .ext-link-label {
    font-weight: 600;
    color: var(--color-text);
  }

  .ext-link-meta {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
    line-height: 1.5;
  }

  .ext-link-toggle {
    flex-shrink: 0;
    width: 44px;
    height: 24px;
    border-radius: 9999px;
    border: none;
    background: var(--color-border);
    position: relative;
    cursor: pointer;
    transition: background-color 0.2s ease;
  }

  .ext-link-toggle.on {
    background: var(--color-success, #16a34a);
  }

  .ext-link-knob {
    position: absolute;
    top: 2px;
    inset-inline-start: 2px;
    width: 20px;
    height: 20px;
    background: white;
    border-radius: 50%;
    transition: inset-inline-start 0.2s ease;
  }

  .ext-link-toggle.on .ext-link-knob {
    inset-inline-start: 22px;
  }

  .pre-trusted-list {
    list-style: none;
    padding: var(--space-3);
    margin: var(--space-2) 0 0 0;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: var(--space-1);
    max-height: 200px;
    overflow-y: auto;
  }

  .pre-trusted-item code {
    font-size: 0.8rem;
    color: var(--color-text-secondary);
  }

  /* ---- Page layout ---- */
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

  /* ---- Fields ---- */
  .stitch-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .stitch-label {
    font-size: 0.6875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--color-text-secondary);
    margin-inline-start: 4px;
  }

  .stitch-input {
    display: block;
    width: 100%;
    padding: 12px 16px;
    background: var(--color-surface-container-high);
    border: none;
    border-radius: 10px;
    font-size: 0.875rem;
    color: var(--color-text);
    transition: background-color 0.2s ease, box-shadow 0.2s ease;
  }

  .stitch-input::placeholder {
    color: var(--color-text-tertiary);
  }

  .stitch-input:focus {
    outline: none;
    background: var(--color-surface-container-lowest);
    box-shadow: 0 0 0 2px rgba(var(--color-primary-rgb), 0.2);
  }

  /* ---- Status row (2FA enabled) ---- */
  .stitch-status-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 12px 0;
    border-block-end: 1px solid var(--scrim-soft);
  }

  .stitch-status-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .stitch-status-label {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--color-text);
  }

  .stitch-status-value {
    font-size: 0.75rem;
    font-weight: 600;
  }

  .stitch-status-enabled {
    color: var(--color-success);
  }

  /* ---- QR & backup codes ---- */
  .stitch-qr {
    display: flex;
    justify-content: center;
    padding: 16px;
  }

  .stitch-qr-img {
    width: 200px;
    height: 200px;
    border-radius: 10px;
    border: 1px solid var(--scrim-soft);
  }

  .stitch-secret {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .stitch-secret-code {
    font-family: var(--font-mono);
    font-size: 0.875rem;
    padding: 10px 14px;
    background: var(--color-surface-container-high);
    border-radius: 10px;
    word-break: break-all;
    user-select: all;
  }

  .stitch-backup {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .stitch-codes-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 8px;
  }

  .stitch-backup-code {
    font-family: var(--font-mono);
    font-size: 0.875rem;
    padding: 6px 10px;
    background: var(--color-surface-container-high);
    border-radius: 8px;
    text-align: center;
    user-select: all;
  }

  /* ---- Error / Success ---- */
  .stitch-error {
    padding: 12px 16px;
    background: var(--color-danger-soft);
    color: var(--color-danger);
    border-radius: 10px;
    font-size: 0.875rem;
  }

  .stitch-success {
    padding: 12px 16px;
    background: var(--color-success-soft);
    color: var(--color-success);
    border-radius: 10px;
    font-size: 0.875rem;
  }

  /* ---- Buttons ---- */
  .stitch-actions {
    display: flex;
    justify-content: flex-end;
    gap: 12px;
    padding-block-start: 8px;
  }

  .stitch-btn-primary {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 10px 28px;
    background: var(--color-primary);
    color: white;
    border: none;
    border-radius: 9999px;
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
    box-shadow: 0 4px 14px rgba(var(--color-primary-rgb), 0.2);
    transition: background-color 0.15s ease, box-shadow 0.15s ease, transform 0.1s ease;
  }

  .stitch-btn-primary:hover:not(:disabled) {
    background: var(--color-primary-hover);
    box-shadow: 0 6px 20px rgba(var(--color-primary-rgb), 0.3);
  }

  .stitch-btn-primary:active:not(:disabled) {
    transform: scale(0.98);
  }

  .stitch-btn-primary:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .stitch-btn-ghost {
    padding: 10px 24px;
    background: transparent;
    border: none;
    border-radius: 9999px;
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--color-text-secondary);
    cursor: pointer;
    transition: color 0.15s ease, background-color 0.15s ease;
  }

  .stitch-btn-ghost:hover {
    color: var(--color-text);
    background: var(--scrim-tint);
  }

  .stitch-btn-outline {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 10px 24px;
    background: transparent;
    border: 1.5px solid var(--color-primary);
    border-radius: 9999px;
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--color-primary);
    cursor: pointer;
    transition: background-color 0.15s ease;
  }

  .stitch-btn-outline:hover:not(:disabled) {
    background: rgba(var(--color-primary-rgb), 0.06);
  }

  .stitch-btn-outline:disabled {
    opacity: 0.6;
    cursor: not-allowed;
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

  /* ---- Responsive ---- */
  @media (max-width: 640px) {
    .stitch-form {
      padding: 20px;
    }

    .stitch-status-row {
      flex-direction: column;
      align-items: flex-start;
      gap: 12px;
    }
  }

  /* Security Keys */
  .keys-list { display: flex; flex-direction: column; gap: 8px; margin-block-end: 16px; }

  .key-item {
    display: flex; align-items: center; justify-content: space-between;
    padding: 12px 16px; background: var(--color-surface); border-radius: 10px;
  }

  .key-info { display: flex; align-items: center; gap: 12px; }
  .key-icon { font-size: 24px; color: var(--color-primary); }
  .key-name { display: block; font-size: 0.875rem; font-weight: 600; }
  .key-meta { display: block; font-size: 0.7rem; color: var(--color-text-tertiary); }

  .key-remove {
    background: none; border: none; color: var(--color-text-tertiary); cursor: pointer;
    padding: 4px; border-radius: 50%;
  }
  .key-remove:hover { color: var(--color-danger); background: var(--color-danger-soft); }

  .key-add-form { display: flex; gap: 8px; }

  .key-name-input {
    flex: 1; padding: 10px 14px; border: 1px solid var(--color-border); border-radius: 10px;
    font-size: 0.875rem; background: var(--color-surface); color: var(--color-text);
  }
  .key-name-input:focus { outline: none; border-color: var(--color-primary); }

  .key-add-btn {
    display: flex; align-items: center; gap: 6px;
    padding: 10px 18px; background: var(--color-primary); color: white; border: none;
    border-radius: 10px; font-size: 0.875rem; font-weight: 600; cursor: pointer; white-space: nowrap;
  }
  .key-add-btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .key-add-btn:hover:not(:disabled) { opacity: 0.9; }
</style>
