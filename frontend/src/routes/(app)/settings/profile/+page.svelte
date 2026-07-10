<script lang="ts">
  import { get } from 'svelte/store';
  import { onMount } from 'svelte';
  import { authStore, setUser, currentUser } from '$lib/stores/auth.js';
  import { updateAccount, updateAvatar, updateHeader } from '$lib/api/accounts.js';
  import { getCurrentUser } from '$lib/api/auth.js';
  import { tError } from '$lib/utils/i18n.js';
  import { addToast } from '$lib/stores/toast.js';
  import type { Identity } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import Spinner from '$lib/components/ui/Spinner.svelte';

  let avatarUploading = $state(false);
  let headerUploading = $state(false);

  let displayName = $state('');
  let bio = $state('');
  let handle = $state('');
  let avatarUrl: string | null = $state(null);
  let headerUrl: string | null = $state(null);
  let showBadge = $state(true);
  let birthday = $state('');
  let location = $state('');
  // Free-form fields user can publish on their profile (Twitter/Mastodon
  // "links + facts" section). Per-tier cap from currentUser.limits;
  // free tier gets 0 (toggle hidden), starter 2, creator 5, pro 10.
  let profileFields = $state<{ name: string; value: string }[]>([]);
  let profileFieldsMax = $derived(($currentUser?.limits as { profile_fields?: number } | undefined)?.profile_fields ?? 0);
  let saving = $state(false);
  let avatarInput: HTMLInputElement | undefined = $state();
  let headerInput: HTMLInputElement | undefined = $state();

  function populate(u: Identity) {
    displayName = u.display_name || '';
    bio = u.bio || '';
    handle = u.handle;
    avatarUrl = u.avatar_url;
    headerUrl = u.header_url;
    showBadge = (u as any).show_badge !== false;
    birthday = u.birthday || '';
    location = u.location || '';
    profileFields = (u.profile_fields ?? []).map((f) => ({ name: f.name, value: f.value }));
  }

  onMount(async () => {
    // Show cached values instantly (no empty flash), then refresh from
    // the server so edits made on another device aren't overwritten with
    // a stale snapshot.
    const cached = get(authStore).user;
    if (cached) populate(cached);
    try {
      const fresh = await getCurrentUser();
      setUser(fresh);
      populate(fresh);
    } catch {
      // Keep cached values.
    }
  });

  function addProfileField() {
    if (profileFields.length >= profileFieldsMax) return;
    profileFields = [...profileFields, { name: '', value: '' }];
  }

  function removeProfileField(i: number) {
    profileFields = profileFields.filter((_, idx) => idx !== i);
  }

  async function handleSave() {
    if (saving) return;
    saving = true;
    try {
      const cleanedFields = profileFields
        .map((f) => ({ name: f.name.trim(), value: f.value.trim() }))
        .filter((f) => f.name !== '' || f.value !== '')
        .slice(0, profileFieldsMax);

      const updated = await updateAccount({
        display_name: displayName,
        bio,
        show_badge: showBadge,
        // Empty strings → null so the row clears, not stores ''.
        birthday: birthday.trim() === '' ? null : birthday,
        location: location.trim() === '' ? null : location,
        profile_fields: cleanedFields,
      });
      setUser(updated);
      populate(updated);
      addToast('Profile saved', 'success');
    } catch (e) {
      addToast(e instanceof Error ? e.message : 'Failed to save profile', 'error');
    } finally {
      saving = false;
    }
  }

  async function handleAvatarChange(e: Event) {
    const input = e.target as HTMLInputElement;
    const file = input.files?.[0];
    if (!file || avatarUploading) return;
    avatarUploading = true;
    try {
      const updated = await updateAvatar(file);
      avatarUrl = updated.avatar_url;
      setUser(updated);
      addToast('Profile picture updated', 'success');
    } catch (err) {
      addToast(err instanceof Error ? tError(err.message) : tError('media.upload_failed'), 'error');
    } finally {
      avatarUploading = false;
      input.value = '';
    }
  }

  async function handleHeaderChange(e: Event) {
    const input = e.target as HTMLInputElement;
    const file = input.files?.[0];
    if (!file || headerUploading) return;
    headerUploading = true;
    try {
      const updated = await updateHeader(file);
      headerUrl = updated.header_url;
      setUser(updated);
      addToast('Header image updated', 'success');
    } catch (err) {
      addToast(err instanceof Error ? tError(err.message) : tError('media.upload_failed'), 'error');
    } finally {
      headerUploading = false;
      input.value = '';
    }
  }

  function handleDiscard() {
    const u = get(authStore).user;
    if (u) populate(u);
  }
</script>

<div class="stitch-settings">

  <!-- Profile Section -->
  <section class="stitch-section">
    <div class="stitch-section-heading">
      <span class="stitch-section-icon" aria-hidden="true">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>
        </svg>
      </span>
      <h2 class="stitch-section-title">Profile</h2>
    </div>

    <div class="stitch-section-content">
      <!-- Header image -->
      <div class="stitch-header-preview" class:busy={headerUploading} onclick={() => !headerUploading && headerInput?.click()} role="button" tabindex="0" onkeydown={(e) => { if (e.key === 'Enter' && !headerUploading) headerInput?.click(); }}>
        <img src={headerUrl || '/images/default-cover.svg'} alt="" class="stitch-header-img" />
        <div class="stitch-header-overlay">
          {#if headerUploading}
            <Spinner size={22} color="#fff" />
          {:else}
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
              <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/>
            </svg>
          {/if}
        </div>
        <input bind:this={headerInput} type="file" accept="image/*" class="visually-hidden" onchange={handleHeaderChange} />
      </div>

      <!-- Avatar -->
      <div class="stitch-avatar-area">
        <button type="button" class="stitch-avatar-btn" class:busy={avatarUploading} onclick={() => avatarInput?.click()} disabled={avatarUploading} aria-label="Change avatar">
          <Avatar src={avatarUrl} name={displayName || handle} size="xl" />
          <div class="stitch-avatar-overlay">
            {#if avatarUploading}
              <Spinner size={20} color="#fff" />
            {:else}
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/>
              </svg>
            {/if}
          </div>
        </button>
        <input bind:this={avatarInput} type="file" accept="image/*" class="visually-hidden" onchange={handleAvatarChange} />
      </div>

      <!-- Form fields -->
      <form class="stitch-form" onsubmit={(e) => { e.preventDefault(); handleSave(); }}>
        <div class="stitch-field">
          <label class="stitch-label" for="display-name">DISPLAY NAME</label>
          <input
            id="display-name"
            type="text"
            class="stitch-input"
            bind:value={displayName}
            placeholder="Your display name"
            maxlength="50"
          />
        </div>

        <div class="stitch-field">
          <label class="stitch-label" for="bio">BIO</label>
          <textarea
            id="bio"
            class="stitch-textarea"
            bind:value={bio}
            placeholder="Tell people about yourself"
            maxlength="500"
            rows="4"
          ></textarea>
          <span class="stitch-hint">{bio.length}/500</span>
        </div>

        <div class="stitch-field">
          <label class="stitch-label" for="handle">HANDLE</label>
          <input
            id="handle"
            type="text"
            class="stitch-input stitch-input-disabled"
            value={handle}
            disabled
          />
          <span class="stitch-hint">Your handle is permanent and cannot be changed. This ensures stable identity across the federation.</span>
        </div>

        <div class="stitch-field-row">
          <div class="stitch-field">
            <label class="stitch-label" for="birthday">BIRTHDAY</label>
            <input
              id="birthday"
              type="date"
              class="stitch-input"
              bind:value={birthday}
            />
            <span class="stitch-hint">Optional. Shown on your profile if set.</span>
          </div>

          <div class="stitch-field">
            <label class="stitch-label" for="location">LOCATION</label>
            <input
              id="location"
              type="text"
              class="stitch-input"
              bind:value={location}
              placeholder="City, Country"
              maxlength="100"
            />
          </div>
        </div>

        {#if profileFieldsMax > 0}
          <div class="stitch-field">
            <div class="stitch-fields-header">
              <span class="stitch-label">PROFILE FIELDS</span>
              <span class="stitch-hint">{profileFields.length}/{profileFieldsMax}</span>
            </div>
            <p class="stitch-hint stitch-fields-help">
              Free-form pairs (e.g. "Website" / "https://…", "Pronouns" / "she/they"). Visible on your public profile.
            </p>
            {#each profileFields as field, i (i)}
              <div class="stitch-fields-row">
                <input
                  type="text"
                  class="stitch-input stitch-fields-name"
                  placeholder="Label"
                  maxlength="60"
                  bind:value={field.name}
                />
                <input
                  type="text"
                  class="stitch-input stitch-fields-value"
                  placeholder="Value"
                  maxlength="280"
                  bind:value={field.value}
                />
                <button
                  type="button"
                  class="stitch-fields-remove"
                  onclick={() => removeProfileField(i)}
                  aria-label="Remove field"
                  title="Remove"
                >
                  ✕
                </button>
              </div>
            {/each}
            {#if profileFields.length < profileFieldsMax}
              <button type="button" class="stitch-btn-ghost stitch-fields-add" onclick={addProfileField}>
                + Add field
              </button>
            {/if}
          </div>
        {:else}
          <p class="stitch-hint stitch-fields-help">
            Custom profile fields are available on Starter tier and above.
          </p>
        {/if}

        <!-- Show badge toggle -->
        <div class="stitch-toggle-row">
          <div class="stitch-toggle-info">
            <span class="stitch-toggle-label">Show role badge</span>
            <span class="stitch-toggle-desc">Display your instance role badge (Admin, Moderator, Owner) on your profile and posts. Group and page badges are always visible.</span>
          </div>
          <label class="stitch-switch">
            <input type="checkbox" bind:checked={showBadge} />
            <span class="stitch-switch-track"></span>
          </label>
        </div>

        <div class="stitch-actions">
          <button class="stitch-btn-ghost" type="button" onclick={handleDiscard}>
            Discard Changes
          </button>
          <button class="stitch-btn-primary" type="submit" disabled={saving}>
            {#if saving}
              <Spinner size={16} color="#fff" />
            {/if}
            Save Settings
          </button>
        </div>
      </form>
    </div>
  </section>
</div>

<style>
  /* ---- Page header ---- */
  .stitch-settings {
    max-width: 720px;
  }

  /* ---- Section ---- */
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

  /* ---- Section content container ---- */
  .stitch-section-content {
    background: var(--color-surface-container-low);
    border-radius: 16px;
    padding: 0;
    overflow: hidden;
  }

  /* ---- Header image ---- */
  .stitch-header-preview {
    height: 160px;
    cursor: pointer;
    position: relative;
    overflow: hidden;
    background: var(--color-surface-container-high);
  }

  .stitch-header-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    transition: opacity 0.2s ease;
  }

  .stitch-header-placeholder {
    width: 100%;
    height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 8px;
    color: var(--color-text-tertiary);
    font-size: 0.8125rem;
  }

  .stitch-header-overlay {
    position: absolute;
    inset: 0;
    background: var(--scrim-medium);
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    opacity: 0;
    transition: opacity 0.2s ease;
  }

  .stitch-header-preview:hover .stitch-header-overlay,
  .stitch-header-preview.busy .stitch-header-overlay,
  .stitch-avatar-btn.busy .stitch-avatar-overlay {
    opacity: 1;
  }

  .stitch-header-preview.busy,
  .stitch-avatar-btn.busy {
    cursor: default;
  }

  /* ---- Avatar ---- */
  .stitch-avatar-area {
    padding-inline-start: 32px;
    margin-block-start: -40px;
    margin-block-end: 8px;
    position: relative;
    z-index: 1;
  }

  .stitch-avatar-btn {
    position: relative;
    border: none;
    padding: 0;
    cursor: pointer;
    background: none;
    display: block;
    border-radius: 50%;
    ring: none;
  }

  .stitch-avatar-btn :global(.avatar) {
    width: 96px !important;
    height: 96px !important;
    ring: 4px solid var(--color-surface);
    box-shadow: var(--shadow-md);
    border: 4px solid var(--color-surface);
    border-radius: 50%;
  }

  .stitch-avatar-overlay {
    position: absolute;
    inset: 0;
    border-radius: 50%;
    background: var(--scrim-medium);
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    opacity: 0;
    transition: opacity 0.2s ease;
  }

  .stitch-avatar-btn:hover .stitch-avatar-overlay {
    opacity: 1;
  }

  /* ---- Form ---- */
  .stitch-form {
    padding: 24px 32px 32px;
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .stitch-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  /* Two-up grid: birthday + location side by side on wide screens,
     stacked on phones. */
  .stitch-field-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
  }

  @media (max-width: 600px) {
    .stitch-field-row {
      grid-template-columns: 1fr;
    }
  }

  .stitch-fields-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .stitch-fields-help {
    margin: 0 0 8px;
  }

  .stitch-fields-row {
    display: flex;
    gap: 8px;
    align-items: center;
    margin-block-end: 8px;
  }

  .stitch-fields-name {
    flex: 0 0 30%;
    min-width: 0;
  }

  .stitch-fields-value {
    flex: 1;
    min-width: 0;
  }

  .stitch-fields-remove {
    flex-shrink: 0;
    width: 32px;
    height: 32px;
    border: 1px solid var(--color-border);
    background: transparent;
    border-radius: var(--radius-md);
    color: var(--color-text-secondary);
    cursor: pointer;
  }

  .stitch-fields-remove:hover {
    background: var(--color-surface);
    color: var(--color-text);
  }

  .stitch-fields-add {
    align-self: flex-start;
    margin-block-start: 4px;
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

  .stitch-input-disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .stitch-textarea {
    display: block;
    width: 100%;
    padding: 12px 16px;
    background: var(--color-surface-container-high);
    border: none;
    border-radius: 10px;
    font-size: 0.875rem;
    color: var(--color-text);
    resize: vertical;
    font-family: inherit;
    transition: background-color 0.2s ease, box-shadow 0.2s ease;
  }

  .stitch-textarea::placeholder {
    color: var(--color-text-tertiary);
  }

  .stitch-textarea:focus {
    outline: none;
    background: var(--color-surface-container-lowest);
    box-shadow: 0 0 0 2px rgba(var(--color-primary-rgb), 0.2);
  }

  .stitch-hint {
    font-size: 0.75rem;
    color: var(--color-text-tertiary);
    margin-inline-start: 4px;
  }

  /* ---- Toggle row ---- */
  .stitch-toggle-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 12px 0;
    border-block-start: 1px solid var(--scrim-soft);
  }

  .stitch-toggle-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .stitch-toggle-label {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--color-text);
  }

  .stitch-toggle-desc {
    font-size: 0.75rem;
    color: var(--color-text-tertiary);
    line-height: 1.4;
  }

  /* Pill-shaped toggle switch */
  .stitch-switch {
    position: relative;
    display: inline-flex;
    cursor: pointer;
    flex-shrink: 0;
  }

  .stitch-switch input {
    position: absolute;
    opacity: 0;
    width: 0;
    height: 0;
  }

  .stitch-switch-track {
    width: 44px;
    height: 24px;
    background: var(--color-border);
    border-radius: 12px;
    position: relative;
    transition: background-color 0.2s ease;
  }

  .stitch-switch-track::after {
    content: '';
    position: absolute;
    top: 2px;
    left: 2px;
    width: 20px;
    height: 20px;
    background: white;
    border-radius: 50%;
    transition: transform 0.2s ease;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.15);
  }

  .stitch-switch input:checked + .stitch-switch-track {
    background: var(--color-primary);
  }

  .stitch-switch input:checked + .stitch-switch-track::after {
    transform: translateX(20px);
  }

  /* ---- Action buttons ---- */
  .stitch-actions {
    display: flex;
    justify-content: flex-end;
    gap: 12px;
    padding-block-start: 8px;
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

  /* ---- Responsive ---- */
  @media (max-width: 640px) {
    .stitch-form {
      padding: 20px;
    }

    .stitch-avatar-area {
      padding-inline-start: 20px;
    }

    .stitch-actions {
      flex-direction: column;
    }

    .stitch-btn-ghost,
    .stitch-btn-primary {
      width: 100%;
      justify-content: center;
    }
  }
</style>
