<script lang="ts">
  import { onMount } from 'svelte';
  import BrandMark from '$lib/components/ui/BrandMark.svelte';
  import Captcha from '$lib/components/auth/Captcha.svelte';
  import { api } from '$lib/api/client.js';
  import { ApiError } from '$lib/api/client.js';
  import { solvePow, type PowChallenge, type PowSolution } from '$lib/utils/pow.js';
  import { tError } from '$lib/utils/i18n.js';
  import { t } from '$lib/stores/i18n.js';
  import { browser } from '$app/environment';
  import { instanceName } from '$lib/stores/instance.js';

  let handle = $state('');
  let email = $state('');
  let password = $state('');
  let passwordConfirm = $state('');
  let agreedToTerms = $state(false);
  let error = $state('');
  let fieldErrors = $state<Record<string, string>>({});
  let loading = $state(false);
  let success = $state(false);

  // Invite code — populated from `?invite=…` when the admin shared
  // a link, or typed manually when the instance requires one.
  let inviteCode = $state('');
  if (browser) {
    const qp = new URLSearchParams(window.location.search).get('invite');
    if (qp) inviteCode = qp;
  }

  // PoW
  let powSolution = $state<PowSolution | null>(null);
  let powSolving = $state(false);

  // Captcha (provider selected by the admin: turnstile | hcaptcha | recaptcha)
  let captchaProvider = $state('none');
  let captchaSiteKey = $state('');
  let captchaToken = $state('');
  let captcha: { getToken: () => Promise<string> } | undefined = $state();
  // Widget providers require the user to complete a challenge before submit;
  // reCAPTCHA v3 is invisible and executed at submit time.
  let captchaWidget = $derived(
    captchaProvider === 'turnstile' || captchaProvider === 'hcaptcha'
  );

  // Registration mode (open | invite_only | approval | closed). The
  // public info endpoint reports it; we gate the form accordingly so
  // users don't fill in a form that the backend will reject.
  type RegMode = 'open' | 'invite_only' | 'approval' | 'closed';
  let registrationMode = $state<RegMode>('open');

  // Tier plans
  interface TierLimits {
    char_limit: number;
    markdown: string;
    video_resolution: number;
    video_duration: number;
    image_size_mb: number;
    video_size_mb: number;
    media_per_post: number;
    poll_options: number;
    edit_window: number;
    pinned_posts: number;
    profile_fields: number;
    scheduled_posts: boolean;
    post_expiry?: boolean;
    custom_emoji: boolean;
    follows_limit: number;
  }

  interface Plan {
    id: string;
    name: string;
    price: number;
    currency: string;
    limits: TierLimits;
  }

  let plans = $state<Plan[]>([]);
  let tiersEnabled = $state(false);
  let paymentConfigured = $state(false);
  let selectedTier = $state('free');
  let showTiers = $state(false);

  let passwordMismatch = $derived(
    passwordConfirm.length > 0 && password !== passwordConfirm
  );

  let passwordTooShort = $derived(
    password.length > 0 && password.length < 16
  );

  let emailInvalid = $derived(
    email.length > 0 && !email.includes('@')
  );

  let handleInvalid = $derived(
    handle.length > 0 && !/^[a-zA-Z0-9_]+$/.test(handle)
  );

  let formValid = $derived(
    handle.length > 0 &&
    !handleInvalid &&
    email.length > 0 &&
    !emailInvalid &&
    password.length >= 16 &&
    password === passwordConfirm &&
    agreedToTerms &&
    !powSolving &&
    (registrationMode !== 'invite_only' || inviteCode.trim().length > 0) &&
    (!captchaWidget || captchaToken.length > 0)
  );

  onMount(() => {
    fetchPowChallenge();
    checkCaptcha();
    fetchPlans();
  });

  async function fetchPlans() {
    try {
      const data = await api.get<{ plans: Plan[]; tiers_enabled: boolean; payment_configured: boolean }>('/api/v1/subscriptions/plans');
      plans = data.plans;
      tiersEnabled = data.tiers_enabled;
      paymentConfigured = data.payment_configured;
    } catch {
      // Plans not available
    }
  }

  async function fetchPowChallenge() {
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
        registration_mode?: RegMode;
      }>('/api/v1/instance/info');
      if (info.captcha_provider && info.captcha_provider !== 'none' && info.captcha_site_key) {
        captchaProvider = info.captcha_provider;
        captchaSiteKey = info.captcha_site_key;
      }
      if (info.registration_mode) registrationMode = info.registration_mode;
    } catch { /* */ }
  }

  async function handleSubmit(e: SubmitEvent) {
    e.preventDefault();
    error = '';
    fieldErrors = {};

    if (handleInvalid) {
      fieldErrors.handle = $t('register.err_handle_chars');
      return;
    }
    if (emailInvalid) {
      fieldErrors.email = $t('register.err_email');
      return;
    }
    if (password.length < 16) {
      fieldErrors.password = $t('register.err_password_short');
      return;
    }
    if (password !== passwordConfirm) {
      fieldErrors.password_confirm = $t('register.err_password_mismatch');
      return;
    }

    loading = true;
    try {
      const body: Record<string, unknown> = { handle, email, password, password_confirmation: passwordConfirm };
      // Flat keys the backend expects (was sending a nested pow_solution).
      if (powSolution) {
        body.pow_prefix = powSolution.challenge;
        body.pow_nonce = powSolution.nonce;
      }
      if (captchaProvider !== 'none' && captcha) {
        body.captcha_token = await captcha.getToken();
      }
      if (inviteCode.trim()) body.invite_code = inviteCode.trim();

      await api.post('/api/v1/auth/register', body);
      success = true;
    } catch (err) {
      if (err instanceof ApiError) {
        error = err.body.error_description || tError(err.body.error);
        if (err.body.details) {
          fieldErrors = {};
          for (const [field, messages] of Object.entries(err.body.details)) {
            fieldErrors[field] = messages[0];
          }
        }
      } else {
        error = $t('login.error_unexpected');
      }
    } finally {
      loading = false;
    }
  }

  function formatPrice(cents: number, currency: string): string {
    if (cents === 0) return $t('register.free');
    return new Intl.NumberFormat(undefined, { style: 'currency', currency }).format(cents / 100);
  }

  function formatEditWindow(seconds: number): string {
    if (seconds === 0) return $t('register.unlimited');
    if (seconds < 3600) return $t('register.minutes', { n: Math.round(seconds / 60) });
    if (seconds < 86400) return $t('register.hours', { n: Math.round(seconds / 3600) });
    return $t('register.days', { n: Math.round(seconds / 86400) });
  }

  function formatFollows(limit: number): string {
    return limit === 0 ? $t('register.unlimited') : String(limit);
  }
</script>

<svelte:head>
  <title>{$t('register.page_title')} - {$instanceName}</title>
</svelte:head>

{#if success}
  <div class="auth-card">
    <div class="auth-success-icon" aria-hidden="true">
      <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
        <polyline points="22 4 12 14.01 9 11.01"/>
      </svg>
    </div>
    <h1 class="auth-title" style="text-align: center;">{$t('register.check_email')}</h1>
    <p class="auth-subtitle" style="text-align: center;">
      {$t('register.sent_to')} <strong dir="ltr">{email}</strong>.
      {$t('register.sent_hint')}
    </p>
    <p class="auth-footer">
      <a href="/login" class="auth-footer-link">{$t('register.back_to_login')}</a>
    </p>
  </div>
{:else}
  <div class="register-layout">
    <!-- Left: Registration form -->
    <div class="auth-card">
      <div class="auth-logo">
        <BrandMark size={40} />
      </div>

      <h1 class="auth-title">{$t('register.title')}</h1>
      <p class="auth-subtitle">{$t('register.subtitle')}</p>

      {#if registrationMode === 'closed'}
        <div class="reg-notice reg-notice-closed" role="status">
          <svg class="reg-notice-icon" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <rect x="3" y="11" width="18" height="11" rx="2" />
            <path d="M7 11V7a5 5 0 0 1 10 0v4" />
          </svg>
          <div>
            <h2 class="reg-notice-title">{$t('register.closed_title')}</h2>
            <p class="reg-notice-text">
              {$t('register.closed_text')} <a href="/login">{$t('register.closed_login')}</a>.
            </p>
          </div>
        </div>
      {:else}
        {#if registrationMode === 'invite_only'}
          <div class="reg-notice reg-notice-info" role="status">
            <svg class="reg-notice-icon" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
              <polyline points="22 4 12 14.01 9 11.01"/>
            </svg>
            <div>
              <h2 class="reg-notice-title">{$t('register.invite_title')}</h2>
              <p class="reg-notice-text">
                {$t('register.invite_text')}
              </p>
            </div>
          </div>
        {:else if registrationMode === 'approval'}
          <div class="reg-notice reg-notice-info" role="status">
            <svg class="reg-notice-icon" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <circle cx="12" cy="12" r="10"/>
              <polyline points="12 6 12 12 16 14"/>
            </svg>
            <div>
              <h2 class="reg-notice-title">{$t('register.approval_title')}</h2>
              <p class="reg-notice-text">
                {$t('register.approval_text')}
              </p>
            </div>
          </div>
        {/if}

        {#if error}
          <div class="auth-error" role="alert">
            <span class="auth-error-icon" aria-hidden="true">!</span>
            {error}
          </div>
        {/if}

        <form onsubmit={handleSubmit} novalidate>
        <div class="auth-field">
          <label for="handle" class="auth-label">{$t('auth.handle')}</label>
          <div class="auth-handle-wrap">
            <span class="auth-handle-prefix" aria-hidden="true">@</span>
            <input id="handle" type="text" class="auth-input auth-handle-input" class:auth-input-error={!!fieldErrors.handle || handleInvalid} placeholder={$t('register.handle_placeholder')} bind:value={handle} required disabled={loading} autocomplete="username" pattern="[a-zA-Z0-9_]+" />
          </div>
          {#if fieldErrors.handle}
            <p class="auth-field-error" role="alert">{fieldErrors.handle}</p>
          {:else if handleInvalid}
            <p class="auth-field-error" role="alert">{$t('register.err_handle_chars')}</p>
          {/if}
        </div>

        <div class="auth-field">
          <label for="reg-invite" class="auth-label">
            {$t('register.invite_label')}
            {#if registrationMode !== 'invite_only'}
              <span class="auth-label-optional">{$t('register.optional')}</span>
            {/if}
          </label>
          <input
            id="reg-invite"
            type="text"
            class="auth-input"
            class:auth-input-error={!!fieldErrors.invite_code}
            placeholder={registrationMode === 'invite_only' ? $t('register.invite_required_ph') : $t('register.invite_optional_ph')}
            bind:value={inviteCode}
            required={registrationMode === 'invite_only'}
            disabled={loading}
            autocomplete="off"
          />
          {#if fieldErrors.invite_code}
            <p class="auth-field-error" role="alert">{fieldErrors.invite_code}</p>
          {/if}
        </div>

        <div class="auth-field">
          <label for="reg-email" class="auth-label">{$t('auth.email')}</label>
          <input id="reg-email" type="email" class="auth-input" class:auth-input-error={!!fieldErrors.email || emailInvalid} placeholder="you@example.com" bind:value={email} required disabled={loading} autocomplete="email" />
          {#if fieldErrors.email}
            <p class="auth-field-error" role="alert">{fieldErrors.email}</p>
          {:else if emailInvalid}
            <p class="auth-field-error" role="alert">{$t('register.err_email')}</p>
          {/if}
        </div>

        <div class="auth-field">
          <label for="reg-password" class="auth-label">{$t('auth.password')}</label>
          <input id="reg-password" type="password" class="auth-input" class:auth-input-error={!!fieldErrors.password || passwordTooShort} placeholder={$t('register.password_ph')} bind:value={password} required minlength={16} disabled={loading} autocomplete="new-password" />
          {#if fieldErrors.password}
            <p class="auth-field-error" role="alert">{fieldErrors.password}</p>
          {:else if passwordTooShort}
            <p class="auth-field-error" role="alert">{$t('register.password_count', { count: password.length })}</p>
          {/if}
        </div>

        <div class="auth-field">
          <label for="reg-password-confirm" class="auth-label">{$t('auth.confirm_password')}</label>
          <input id="reg-password-confirm" type="password" class="auth-input" class:auth-input-error={passwordMismatch} placeholder={$t('register.confirm_ph')} bind:value={passwordConfirm} required disabled={loading} autocomplete="new-password" />
          {#if passwordMismatch}
            <p class="auth-field-error" role="alert">{$t('register.err_password_mismatch')}</p>
          {/if}
        </div>

        {#if captchaProvider !== 'none' && captchaSiteKey}
          <div class="auth-field">
            <Captcha
              bind:this={captcha}
              provider={captchaProvider}
              siteKey={captchaSiteKey}
              bind:token={captchaToken}
              action="register"
            />
          </div>
        {/if}

        <div class="auth-field auth-checkbox-field">
          <label class="auth-checkbox-label">
            <input type="checkbox" bind:checked={agreedToTerms} disabled={loading} class="auth-checkbox" />
            <span class="auth-checkbox-text">
              {$t('register.agree')} <a href="/legal/terms" target="_blank" rel="noopener" class="auth-link">{$t('register.terms')}</a>
              {$t('register.and')} <a href="/legal/privacy" target="_blank" rel="noopener" class="auth-link">{$t('register.privacy')}</a>
            </span>
          </label>
        </div>

        {#if powSolving}
          <p class="auth-pow-status">
            <span class="auth-spinner-small" aria-hidden="true"></span>
            {$t('register.solving')}
          </p>
        {/if}

        <button type="submit" class="auth-submit" disabled={loading || !formValid}>
          {#if loading}
            <span class="auth-spinner" aria-hidden="true"></span>
            {$t('register.creating')}
          {:else}
            {$t('register.page_title')}
          {/if}
        </button>
      </form>
      {/if}

      <p class="auth-footer">
        {$t('register.have_account')} <a href="/login" class="auth-footer-link">{$t('auth.login')}</a>
      </p>
    </div>

    <!-- Right: Plans & tiers -->
    {#if tiersEnabled && plans.length > 0}
      <div class="plans-section">
        <h2 class="plans-title">{$t('register.plans_title')}</h2>
        <p class="plans-subtitle">{$t('register.plans_subtitle')}</p>

        <div class="plans-grid">
          {#each plans as plan (plan.id)}
            <button
              type="button"
              class="plan-card"
              class:plan-selected={selectedTier === plan.id}
              class:plan-popular={plan.id === 'verified_creator'}
              onclick={() => selectedTier = plan.id}
            >
              {#if plan.id === 'verified_creator'}
                <span class="plan-badge">{$t('register.most_popular')}</span>
              {/if}

              <h3 class="plan-name">{plan.name}</h3>
              <div class="plan-price">
                <span class="plan-amount">{formatPrice(plan.price, plan.currency)}</span>
                {#if plan.price > 0}
                  <span class="plan-period">{$t('register.per_month')}</span>
                {/if}
              </div>

              <ul class="plan-features">
                <li>
                  <span class="plan-check">&#10003;</span>
                  {$t('register.feat_chars', { n: plan.limits.char_limit })}
                </li>
                <li>
                  <span class="plan-check">&#10003;</span>
                  {$t('register.feat_media', { n: plan.limits.media_per_post })}
                </li>
                <li>
                  <span class="plan-check">&#10003;</span>
                  {$t('register.feat_edit', { window: formatEditWindow(plan.limits.edit_window) })}
                </li>
                <li>
                  <span class="plan-check">&#10003;</span>
                  {$t('register.feat_pinned', { count: plan.limits.pinned_posts })}
                </li>
                <li>
                  <span class="plan-check">&#10003;</span>
                  {$t('register.feat_follows', { n: formatFollows(plan.limits.follows_limit) })}
                </li>
                {#if plan.limits.scheduled_posts}
                  <li><span class="plan-check">&#10003;</span> {$t('register.feat_scheduled')}</li>
                {/if}
                {#if plan.limits.custom_emoji}
                  <li><span class="plan-check">&#10003;</span> {$t('register.feat_custom_emoji')}</li>
                {/if}
                {#if plan.limits.markdown !== 'none'}
                  <li><span class="plan-check">&#10003;</span> Markdown ({plan.limits.markdown})</li>
                {/if}
                <li class="plan-feature-muted">
                  {$t('register.feat_sizes', { image: plan.limits.image_size_mb, video: plan.limits.video_size_mb })}
                </li>
                {#if plan.limits.video_resolution >= 1080}
                  <li><span class="plan-check">&#10003;</span> {$t('register.feat_hd')}</li>
                {/if}
              </ul>
            </button>
          {/each}
        </div>

        {#if !paymentConfigured && plans.some(p => p.price > 0)}
          <p class="plans-note">{$t('register.plans_note')}</p>
        {/if}

        <button type="button" class="plans-compare-btn" onclick={() => showTiers = !showTiers}>
          {showTiers ? $t('register.compare_hide') : $t('register.compare_show')}
          <span class="material-symbols-outlined" style="font-size: 18px">{showTiers ? 'expand_less' : 'expand_more'}</span>
        </button>

        {#if showTiers}
          <div class="compare-table-wrap">
            <table class="compare-table">
              <thead>
                <tr>
                  <th>{$t('register.col_feature')}</th>
                  {#each plans as plan (plan.id)}
                    <th class:compare-highlight={selectedTier === plan.id}>{plan.name}</th>
                  {/each}
                </tr>
              </thead>
              <tbody>
                <tr><td>{$t('register.row_chars')}</td>{#each plans as p (p.id)}<td>{p.limits.char_limit}</td>{/each}</tr>
                <tr><td>{$t('register.row_media')}</td>{#each plans as p (p.id)}<td>{p.limits.media_per_post}</td>{/each}</tr>
                <tr><td>{$t('register.row_image')}</td>{#each plans as p (p.id)}<td>{p.limits.image_size_mb} MB</td>{/each}</tr>
                <tr><td>{$t('register.row_video_size')}</td>{#each plans as p (p.id)}<td>{p.limits.video_size_mb} MB</td>{/each}</tr>
                <tr><td>{$t('register.row_video_quality')}</td>{#each plans as p (p.id)}<td>{p.limits.video_resolution}p</td>{/each}</tr>
                <tr><td>{$t('register.row_video_duration')}</td>{#each plans as p (p.id)}<td>{$t('register.minutes', { n: Math.round(p.limits.video_duration / 60) })}</td>{/each}</tr>
                <tr><td>{$t('register.row_poll')}</td>{#each plans as p (p.id)}<td>{p.limits.poll_options}</td>{/each}</tr>
                <tr><td>{$t('register.row_edit')}</td>{#each plans as p (p.id)}<td>{formatEditWindow(p.limits.edit_window)}</td>{/each}</tr>
                <tr><td>{$t('register.row_pinned')}</td>{#each plans as p (p.id)}<td>{p.limits.pinned_posts}</td>{/each}</tr>
                <tr><td>{$t('register.row_fields')}</td>{#each plans as p (p.id)}<td>{p.limits.profile_fields}</td>{/each}</tr>
                <tr><td>{$t('register.row_follows')}</td>{#each plans as p (p.id)}<td>{formatFollows(p.limits.follows_limit)}</td>{/each}</tr>
                <tr><td>{$t('register.feat_scheduled')}</td>{#each plans as p (p.id)}<td>{p.limits.scheduled_posts ? '✓' : '✗'}</td>{/each}</tr>
                <tr><td>{$t('register.plan_timed_posts')}</td>{#each plans as p (p.id)}<td>{p.limits.post_expiry ? '✓' : '✗'}</td>{/each}</tr>
                <tr><td>{$t('register.feat_custom_emoji')}</td>{#each plans as p (p.id)}<td>{p.limits.custom_emoji ? '✓' : '✗'}</td>{/each}</tr>
                <tr><td>Markdown</td>{#each plans as p (p.id)}<td>{p.limits.markdown}</td>{/each}</tr>
                <tr><td class="compare-price-row">{$t('register.row_price')}</td>{#each plans as p (p.id)}<td class="compare-price-row">{formatPrice(p.price, p.currency)}{p.price > 0 ? $t('register.per_month_short') : ''}</td>{/each}</tr>
              </tbody>
            </table>
          </div>
        {/if}
      </div>
    {/if}
  </div>
{/if}

<style>
  .register-layout {
    display: flex;
    gap: 32px;
    align-items: flex-start;
    max-width: 960px;
    margin: 0 auto;
    padding: 0 16px;
  }

  /* ---- Auth Card ---- */
  .auth-card {
    background: var(--color-surface-container-lowest);
    border-radius: 14px;
    padding: 32px;
    box-shadow: var(--shadow-md);
    flex: 1;
    min-width: 0;
    max-width: 420px;
    animation: fadeUp 0.5s cubic-bezier(0.22, 1, 0.36, 1) 0.1s both;
  }

  .auth-card:focus-within {
    box-shadow: var(--shadow-lg);
  }

  .auth-logo { display: flex; justify-content: center; margin-block-end: 24px; }
  .auth-title { font-family: var(--font-sans); font-size: 1.25rem; font-weight: 700; color: var(--color-text); margin-block-end: 4px; }
  .auth-subtitle { font-size: 0.875rem; color: var(--color-text-secondary); margin-block-end: 24px; }
  .auth-success-icon { display: flex; justify-content: center; margin-block-end: 16px; color: var(--color-success); }

  .auth-error { display: flex; align-items: center; gap: 8px; padding: 12px 16px; margin-block-end: 16px; background: var(--color-danger-soft); border-radius: 10px; color: var(--color-danger); font-size: 0.875rem; }

  .reg-notice {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 14px 16px;
    margin-block-end: 18px;
    border-radius: 12px;
    border: 1px solid transparent;
    font-size: 0.9rem;
    line-height: 1.5;
  }

  .reg-notice-icon {
    flex-shrink: 0;
    margin-block-start: 2px;
  }

  .reg-notice-title {
    margin: 0 0 4px;
    font-size: 0.95rem;
    font-weight: 700;
  }

  .reg-notice-text {
    margin: 0;
    color: var(--color-text-secondary);
  }

  .reg-notice-text a {
    color: var(--color-primary);
    font-weight: 600;
  }

  .reg-notice-closed {
    background: var(--color-danger-soft, #fef2f2);
    border-color: rgba(220, 38, 38, 0.25);
    color: var(--color-on-danger-soft);
  }

  .reg-notice-info {
    background: var(--color-secondary-container, #eef2ff);
    border-color: rgba(99, 102, 241, 0.25);
    color: var(--color-primary);
  }
  .auth-error-icon { display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; border-radius: 50%; background: var(--color-danger); color: white; font-size: 0.75rem; font-weight: 700; flex-shrink: 0; }

  .auth-field { margin-block-end: 16px; }
  .auth-label { display: block; font-size: 0.6875rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; color: var(--color-text-secondary); margin-block-end: 6px; margin-inline-start: 4px; }
  .auth-label-optional { font-weight: 500; color: var(--color-text-tertiary); }
  .auth-input { display: block; width: 100%; height: 46px; padding: 0 16px; background: var(--color-surface-container-high); border: none; border-radius: 10px; font-size: 0.875rem; color: var(--color-text); transition: background-color 0.2s ease, box-shadow 0.2s ease; }
  .auth-input::placeholder { color: var(--color-text-tertiary); }
  .auth-input:focus { outline: none; background: var(--color-surface-container-lowest); box-shadow: 0 0 0 2px rgba(var(--color-primary-rgb), 0.2); }
  .auth-input:disabled { opacity: 0.5; cursor: not-allowed; }
  .auth-input-error { box-shadow: 0 0 0 2px #fca5a5; }

  .auth-handle-wrap { position: relative; display: flex; align-items: center; }
  .auth-handle-prefix { position: absolute; inset-inline-start: 16px; color: var(--color-text-tertiary); font-size: 0.875rem; pointer-events: none; }
  .auth-handle-input { padding-inline-start: 32px; }
  .auth-field-error { font-size: 0.75rem; color: var(--color-danger); margin-block-start: 4px; margin-inline-start: 4px; }

  .auth-checkbox-field { margin-block-start: 20px; }
  .auth-checkbox-label { display: flex; align-items: flex-start; gap: 10px; cursor: pointer; }
  .auth-checkbox { margin-block-start: 2px; accent-color: var(--color-primary); flex-shrink: 0; width: 16px; height: 16px; }
  .auth-checkbox-text { font-size: 0.8125rem; color: var(--color-text-secondary); line-height: 1.5; }
  .auth-link { color: var(--color-primary); text-decoration: none; font-weight: 500; }
  .auth-link:hover { opacity: 0.8; }

  .auth-pow-status { display: flex; align-items: center; gap: 8px; font-size: 0.75rem; color: var(--color-text-secondary); margin-block-end: 12px; }
  .auth-spinner-small { display: inline-block; width: 12px; height: 12px; border: 2px solid var(--color-text-tertiary); border-inline-end-color: transparent; border-radius: 50%; animation: spin 0.6s linear infinite; }

  .auth-submit { display: flex; align-items: center; justify-content: center; gap: 8px; width: 100%; height: 46px; margin-block-start: 20px; padding: 0 20px; background: linear-gradient(135deg, var(--color-primary) 0%, var(--color-primary-hover, var(--color-primary)) 100%); color: white; border: none; border-radius: 9999px; font-size: 0.875rem; font-weight: 600; cursor: pointer; box-shadow: 0 4px 14px rgba(var(--color-primary-rgb), 0.25); transition: box-shadow 0.15s ease, transform 0.1s ease, opacity 0.15s ease; }
  .auth-submit:hover:not(:disabled) { box-shadow: 0 6px 20px rgba(var(--color-primary-rgb), 0.35); }
  .auth-submit:active:not(:disabled) { transform: scale(0.985); }
  .auth-submit:disabled { opacity: 0.6; cursor: not-allowed; }

  .auth-footer { text-align: center; margin-block-start: 24px; font-size: 0.875rem; color: var(--color-text-secondary); }
  .auth-footer-link { color: var(--color-primary); text-decoration: none; font-weight: 500; }
  .auth-footer-link:hover { opacity: 0.8; }

  .auth-spinner { display: inline-block; width: 16px; height: 16px; border: 2px solid currentColor; border-inline-end-color: transparent; border-radius: 50%; animation: spin 0.6s linear infinite; }

  @keyframes spin { to { transform: rotate(360deg); } }
  @keyframes fadeUp {
    from { opacity: 0; transform: translateY(16px); }
    to { opacity: 1; transform: translateY(0); }
  }

  @media (prefers-reduced-motion: reduce) { .auth-card { animation: none !important; } }

  /* ---- Plans Section ---- */
  .plans-section {
    flex: 1;
    min-width: 0;
    animation: fadeUp 0.5s cubic-bezier(0.22, 1, 0.36, 1) 0.2s both;
  }

  .plans-title {
    font-family: var(--font-sans);
    font-size: 1.25rem;
    font-weight: 700;
    color: var(--color-text);
    margin-block-end: 4px;
  }

  .plans-subtitle {
    font-size: 0.875rem;
    color: var(--color-text-secondary);
    margin-block-end: 20px;
  }

  .plans-grid {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .plan-card {
    position: relative;
    text-align: start;
    padding: 16px 18px;
    background: var(--color-surface-container-lowest);
    border: 2px solid var(--color-border, #e5e7eb);
    border-radius: 14px;
    cursor: pointer;
    transition: border-color 150ms ease, box-shadow 150ms ease;
  }

  .plan-card:hover {
    border-color: var(--color-primary);
  }

  .plan-selected {
    border-color: var(--color-primary);
    box-shadow: 0 0 0 1px var(--color-primary), 0 4px 12px rgba(var(--color-primary-rgb), 0.1);
  }

  .plan-badge {
    position: absolute;
    top: -10px;
    inset-inline-end: 16px;
    background: var(--color-primary);
    color: white;
    font-size: 0.65rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    padding: 2px 10px;
    border-radius: 9999px;
  }

  .plan-name {
    font-size: 1rem;
    font-weight: 700;
    color: var(--color-text);
    margin-block-end: 2px;
  }

  .plan-price {
    display: flex;
    align-items: baseline;
    gap: 2px;
    margin-block-end: 10px;
  }

  .plan-amount {
    font-size: 1.25rem;
    font-weight: 800;
    color: var(--color-text);
  }

  .plan-period {
    font-size: 0.75rem;
    color: var(--color-text-secondary);
  }

  .plan-features {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-wrap: wrap;
    gap: 4px 16px;
  }

  .plan-features li {
    font-size: 0.75rem;
    color: var(--color-text);
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .plan-check {
    color: var(--color-primary);
    font-weight: 700;
    font-size: 0.7rem;
  }

  .plan-feature-muted {
    color: var(--color-text-tertiary) !important;
    font-size: 0.7rem !important;
  }

  .plans-note {
    font-size: 0.75rem;
    color: var(--color-text-tertiary);
    text-align: center;
    margin-block-start: 12px;
  }

  /* Compare button */
  .plans-compare-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 4px;
    width: 100%;
    margin-block-start: 16px;
    padding: 8px;
    background: none;
    border: 1px solid var(--color-border, #e5e7eb);
    border-radius: 10px;
    color: var(--color-text-secondary);
    font-size: 0.8125rem;
    font-weight: 600;
    cursor: pointer;
    transition: background 150ms ease;
  }

  .plans-compare-btn:hover {
    background: var(--color-surface, #f9fafb);
  }

  /* Compare table */
  .compare-table-wrap {
    margin-block-start: 12px;
    overflow-x: auto;
    border: 1px solid var(--color-border, #e5e7eb);
    border-radius: 12px;
    animation: fadeUp 0.2s ease;
  }

  .compare-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.75rem;
  }

  .compare-table th,
  .compare-table td {
    padding: 8px 10px;
    text-align: center;
    border-bottom: 1px solid var(--color-border, #f0f0f0);
  }

  .compare-table th {
    font-weight: 700;
    color: var(--color-text);
    background: var(--color-surface, #f9fafb);
    position: sticky;
    top: 0;
  }

  .compare-table th:first-child,
  .compare-table td:first-child {
    text-align: start;
    font-weight: 600;
    color: var(--color-text-secondary);
  }

  .compare-highlight {
    color: var(--color-primary) !important;
  }

  .compare-price-row {
    font-weight: 700 !important;
    color: var(--color-text) !important;
    background: var(--color-surface, #f9fafb);
  }

  /* Responsive */
  @media (max-width: 768px) {
    .register-layout {
      flex-direction: column;
    }

    .auth-card {
      max-width: none;
    }
  }
</style>
