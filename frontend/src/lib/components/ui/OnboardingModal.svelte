<script lang="ts">
  import { api } from '$lib/api/client.js';
  import { uploadMedia } from '$lib/api/media.js';
  import { authStore, setUser } from '$lib/stores/auth.js';
  import { get } from 'svelte/store';
  import type { Identity } from '$lib/api/types.js';
  import Avatar from './Avatar.svelte';

  let {
    onclose,
  }: {
    onclose: () => void;
  } = $props();

  let step = $state(1);
  const totalSteps = 3;

  // Step 1: Avatar, header, display name, bio
  let displayName = $state(get(authStore).user?.display_name || '');
  let bio = $state('');
  let avatarFile: File | null = $state(null);
  let avatarPreview = $state(get(authStore).user?.avatar_url || '');
  let headerFile: File | null = $state(null);
  let headerPreview = $state(get(authStore).user?.header_url || '');

  // Step 2: Suggestions
  let suggestions = $state<Identity[]>([]);
  let followedIds = $state<Set<string>>(new Set());
  let suggestionsLoading = $state(false);

  // Step 3: Privacy — link-preview unfurl default. Opt-out model: users
  // keep this checked unless they specifically want private profiles.
  let allowUnfurl = $state(true);

  let saving = $state(false);
  let saveError = $state('');

  function handleAvatarChange(e: Event) {
    const input = e.target as HTMLInputElement;
    const file = input.files?.[0];
    if (file) {
      avatarFile = file;
      avatarPreview = URL.createObjectURL(file);
    }
  }

  function handleHeaderChange(e: Event) {
    const input = e.target as HTMLInputElement;
    const file = input.files?.[0];
    if (file) {
      headerFile = file;
      headerPreview = URL.createObjectURL(file);
    }
  }

  async function saveProfile(): Promise<boolean> {
    saveError = '';
    // Avatar + header arrive as Files and have to ride through the
    // media endpoint first so the credentials PATCH can reference
    // them by URL — `update_credentials` accepts `avatar_url` /
    // `header_url`, not raw multipart.
    let avatarUrl: string | undefined;
    let headerUrl: string | undefined;
    if (avatarFile) {
      try {
        const media = await uploadMedia(avatarFile);
        avatarUrl = media.url;
      } catch (err) {
        console.error('Avatar upload failed during onboarding', err);
        saveError = err instanceof Error && err.message
          ? `Couldn't upload your profile photo: ${err.message}`
          : "Couldn't upload your profile photo. Please try again.";
        return false;
      }
    }
    if (headerFile) {
      try {
        const media = await uploadMedia(headerFile);
        headerUrl = media.url;
      } catch (err) {
        console.error('Header upload failed during onboarding', err);
        saveError = err instanceof Error && err.message
          ? `Couldn't upload your cover photo: ${err.message}`
          : "Couldn't upload your cover photo. Please try again.";
        return false;
      }
    }

    const body: Record<string, unknown> = {};
    if (displayName.trim()) body.display_name = displayName.trim();
    if (bio.trim()) body.bio = bio.trim();
    if (avatarUrl) body.avatar_url = avatarUrl;
    if (headerUrl) body.header_url = headerUrl;
    if (Object.keys(body).length === 0) return true;

    try {
      const updated = await api.patch<Identity>('/api/v1/accounts/update_credentials', body);
      setUser(updated);
      return true;
    } catch (err) {
      console.error('Profile save failed during onboarding', err);
      saveError = err instanceof Error && err.message
        ? err.message
        : "Couldn't save your profile. Please try again.";
      return false;
    }
  }

  async function loadSuggestions() {
    suggestionsLoading = true;
    try {
      suggestions = await api.get<Identity[]>('/api/v1/accounts/suggestions');
    } catch { suggestions = []; }
    finally { suggestionsLoading = false; }
  }

  async function toggleFollow(id: string) {
    try {
      if (followedIds.has(id)) {
        await api.post(`/api/v1/accounts/${id}/unfollow`);
        followedIds.delete(id);
        followedIds = new Set(followedIds);
      } else {
        await api.post(`/api/v1/accounts/${id}/follow`);
        followedIds.add(id);
        followedIds = new Set(followedIds);
      }
    } catch { /* */ }
  }

  async function markOnboarded() {
    try {
      const updated = await api.patch<Identity>(
        '/api/v1/accounts/update_credentials',
        { onboarded: true, allow_unfurl: allowUnfurl },
      );
      setUser(updated);
    } catch { /* */ }
  }

  async function next() {
    if (saving) return;
    if (step === 1) {
      saving = true;
      const ok = await saveProfile();
      saving = false;
      // Block advancing on failure so the user can fix and retry —
      // silently moving on is what made the form feel like it never
      // saved anything.
      if (!ok) return;
      await loadSuggestions();
      step = 2;
    } else if (step === 2) {
      step = 3;
    } else {
      saving = true;
      await markOnboarded();
      saving = false;
      onclose();
    }
  }

  async function skip() {
    // Skip means "never show this again" — persist and close from any step.
    await markOnboarded();
    onclose();
  }
</script>

<div class="onboarding-overlay" role="dialog" aria-modal="true">
  <div class="onboarding-modal">
    <!-- Progress -->
    <div class="onboarding-progress">
      {#each Array(totalSteps) as _, i}
        <div class="progress-dot" class:active={i + 1 <= step}></div>
      {/each}
    </div>

    {#if step === 1}
      <!-- Step 1: Profile setup -->
      <div class="onboarding-step">
        <h2 class="step-title">Set up your profile</h2>
        <p class="step-desc">Let people know who you are</p>

        <!-- Cover photo (header) + avatar overlap — same pattern the
             public profile uses, so the user is configuring exactly
             what others will see. Both are real <label> elements
             wrapping a hidden <input type="file">, which is the only
             reliable mobile pattern (some mobile browsers won't let a
             scripted .click() open the file picker outside a trusted
             click, but a <label>'s for= relationship always does). -->
        <div class="profile-photo-stack">
          <label class="header-upload" aria-label="Add a cover photo">
            {#if headerPreview}
              <img src={headerPreview} alt="" class="header-preview" />
            {:else}
              <div class="header-placeholder">
                <span class="material-symbols-outlined">add_photo_alternate</span>
                <span class="header-placeholder-text">Add a cover photo</span>
              </div>
            {/if}
            <span class="upload-pill" aria-hidden="true">
              <span class="material-symbols-outlined upload-pill-icon">photo_camera</span>
            </span>
            <input type="file" accept="image/*" class="visually-hidden" onchange={handleHeaderChange} />
          </label>

          <label class="avatar-upload" aria-label="Add a profile photo">
            {#if avatarPreview}
              <img src={avatarPreview} alt="" class="avatar-preview" />
            {:else}
              <div class="avatar-placeholder-big">
                <span class="material-symbols-outlined" style="font-size: 28px">add_a_photo</span>
              </div>
            {/if}
            <span class="upload-pill avatar-upload-pill" aria-hidden="true">
              <span class="material-symbols-outlined upload-pill-icon">photo_camera</span>
            </span>
            <input type="file" accept="image/*" class="visually-hidden" onchange={handleAvatarChange} />
          </label>
        </div>

        <div class="field">
          <label class="field-label" for="ob-name">Display name</label>
          <input id="ob-name" type="text" class="field-input" bind:value={displayName} placeholder="Your name" />
        </div>

        <div class="field">
          <label class="field-label" for="ob-bio">Bio</label>
          <textarea id="ob-bio" class="field-input field-textarea" bind:value={bio} placeholder="Tell us about yourself..." rows={3}></textarea>
        </div>

        {#if saveError}
          <p class="save-error" role="alert">{saveError}</p>
        {/if}
      </div>

    {:else if step === 2}
      <!-- Step 2: Follow suggestions -->
      <div class="onboarding-step">
        <h2 class="step-title">Find people to follow</h2>
        <p class="step-desc">Your feed is built from the people you follow</p>

        {#if suggestionsLoading}
          <div class="suggestions-loading">Loading suggestions...</div>
        {:else if suggestions.length === 0}
          <div class="suggestions-loading">No suggestions yet — you can find people in Explore</div>
        {:else}
          <div class="suggestions-list">
            {#each suggestions as user (user.id)}
              <div class="suggestion-row">
                <Avatar src={user.avatar_url} name={user.display_name || user.handle} size="md" />
                <div class="suggestion-info">
                  <span class="suggestion-name">{user.display_name || user.handle}</span>
                  <span class="suggestion-handle">@{user.acct || user.handle}</span>
                </div>
                <button
                  type="button"
                  class="follow-btn"
                  class:following={followedIds.has(user.id)}
                  onclick={() => toggleFollow(user.id)}
                >
                  {followedIds.has(user.id) ? 'Following' : 'Follow'}
                </button>
              </div>
            {/each}
          </div>
        {/if}
      </div>

    {:else}
      <!-- Step 3: Privacy preference + Done -->
      <div class="onboarding-step done-step">
        <div class="done-icon">
          <span class="material-symbols-outlined" style="font-size: 48px; color: var(--color-success)">check_circle</span>
        </div>
        <h2 class="step-title">You're all set!</h2>
        <p class="step-desc">One last thing before you start.</p>

        <label class="unfurl-row">
          <input type="checkbox" bind:checked={allowUnfurl} />
          <div class="unfurl-body">
            <span class="unfurl-label">Let link previews show my profile</span>
            <span class="unfurl-desc">
              When someone shares a link to your profile on WhatsApp, Telegram,
              Facebook, or Discord, the link can unfurl into a preview card
              with your display name, avatar, and bio. Search engines also
              use this to index your profile page. You can change this any
              time in Settings → Privacy.
            </span>
          </div>
        </label>
      </div>
    {/if}

    <div class="onboarding-actions">
      <button type="button" class="skip-btn" onclick={skip} disabled={saving}>
        {step === totalSteps ? 'Close' : 'Skip for now'}
      </button>
      <button type="button" class="next-btn" onclick={next} disabled={saving}>
        {#if saving}
          Saving…
        {:else if step === totalSteps}
          Get started
        {:else}
          Continue
        {/if}
      </button>
    </div>
  </div>
</div>

<style>
  .onboarding-overlay {
    position: fixed;
    inset: 0;
    background: var(--scrim-medium);
    backdrop-filter: blur(4px);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 10000;
    animation: fade-in 0.2s ease;
  }

  @keyframes fade-in { from { opacity: 0; } to { opacity: 1; } }

  .onboarding-modal {
    background: var(--color-surface-container-lowest);
    border-radius: 20px;
    width: 90%;
    max-width: 440px;
    padding: 32px;
    box-shadow: 0 20px 60px rgba(0, 0, 0, 0.2);
    animation: modal-in 0.25s cubic-bezier(0.22, 1, 0.36, 1);
  }

  @keyframes modal-in {
    from { opacity: 0; transform: scale(0.95) translateY(10px); }
    to { opacity: 1; transform: scale(1) translateY(0); }
  }

  .onboarding-progress {
    display: flex;
    justify-content: center;
    gap: 8px;
    margin-bottom: 24px;
  }

  .progress-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--color-border);
    transition: background 200ms ease, transform 200ms ease;
  }

  .progress-dot.active {
    background: var(--color-primary);
    transform: scale(1.2);
  }

  .step-title {
    font-size: 1.25rem;
    font-weight: 700;
    text-align: center;
    margin-bottom: 4px;
  }

  .step-desc {
    font-size: 0.875rem;
    color: var(--color-text-secondary);
    text-align: center;
    margin-bottom: 24px;
  }

  /* Cover-photo strip + avatar that overlaps its bottom edge, same
     visual language as the public profile page. Whole strip and the
     avatar are real <label>s so iOS Safari opens the file picker on
     tap without needing scripted .click() shenanigans. */
  .profile-photo-stack {
    position: relative;
    margin-block-end: 20px;
  }

  .header-upload {
    display: block;
    position: relative;
    width: 100%;
    aspect-ratio: 3 / 1;
    border-radius: 12px;
    overflow: hidden;
    cursor: pointer;
    background: var(--color-surface);
    border: 2px dashed var(--color-border);
    transition: border-color 150ms ease;
  }

  .header-upload:hover,
  .header-upload:focus-within {
    border-color: var(--color-primary);
  }

  .header-preview {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }

  .header-placeholder {
    width: 100%;
    height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 4px;
    color: var(--color-text-tertiary);
    font-size: 0.8125rem;
  }

  .header-placeholder .material-symbols-outlined {
    font-size: 28px;
  }

  .header-placeholder-text {
    font-weight: 500;
  }

  /* Small "tap to upload" hint badge anchored bottom-right of the
     hero — keeps the affordance discoverable even when the user
     already has a cover photo set. */
  .upload-pill {
    position: absolute;
    inset-block-end: 8px;
    inset-inline-end: 8px;
    background: rgba(0, 0, 0, 0.6);
    color: white;
    border-radius: 9999px;
    width: 30px;
    height: 30px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .upload-pill-icon {
    font-size: 16px;
  }

  /* Avatar overlaps the bottom of the header (Facebook-style) so the
     user can see both photos in their composed form before saving. */
  .avatar-upload {
    position: absolute;
    inset-block-end: -28px;
    inset-inline-start: 16px;
    width: 80px;
    height: 80px;
    border-radius: 50%;
    cursor: pointer;
    overflow: visible;
    border: 3px solid var(--color-surface-container-lowest);
    background: var(--color-surface);
    transition: transform 150ms ease;
    margin: 0;
  }

  .avatar-upload:hover,
  .avatar-upload:focus-within {
    transform: scale(1.03);
  }

  .avatar-upload .avatar-preview,
  .avatar-upload .avatar-placeholder-big {
    border-radius: 50%;
    overflow: hidden;
  }

  .avatar-upload-pill {
    inset-block-end: 0;
    inset-inline-end: 0;
    width: 26px;
    height: 26px;
  }

  /* Push the next field below the avatar's overhang so the display
     name input doesn't collide with the circle. */
  .profile-photo-stack + .field {
    margin-block-start: 36px;
  }

  .avatar-preview {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  .avatar-placeholder-big {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--color-text-tertiary);
  }

  .field { margin-bottom: 16px; }
  .field-label {
    display: block;
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-text-secondary);
    margin-bottom: 6px;
  }
  .field-input {
    width: 100%;
    padding: 10px 14px;
    border: 1px solid var(--color-border);
    border-radius: 10px;
    font-size: 0.875rem;
    color: var(--color-text);
    background: var(--color-surface);
  }
  .field-input:focus {
    outline: none;
    border-color: var(--color-primary);
    box-shadow: 0 0 0 2px var(--color-primary-soft, rgba(108, 62, 221, 0.1));
  }
  .field-textarea { resize: vertical; font-family: inherit; }

  .visually-hidden {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
  }

  .suggestions-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
    max-height: 300px;
    overflow-y: auto;
  }

  .suggestion-row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px;
    border-radius: 10px;
    transition: background 150ms ease;
  }

  .suggestion-row:hover { background: var(--color-surface); }

  .suggestion-info { flex: 1; min-width: 0; }
  .suggestion-name { display: block; font-size: 0.875rem; font-weight: 600; }
  .suggestion-handle { display: block; font-size: 0.75rem; color: var(--color-text-secondary); }

  .follow-btn {
    padding: 6px 16px;
    border: 2px solid var(--color-primary);
    border-radius: 9999px;
    background: transparent;
    color: var(--color-primary);
    font-size: 0.8125rem;
    font-weight: 600;
    cursor: pointer;
    transition: all 150ms ease;
    flex-shrink: 0;
  }

  .follow-btn:hover { background: var(--color-primary); color: white; }
  .follow-btn.following { background: var(--color-primary); color: white; }
  .follow-btn.following:hover { background: transparent; color: var(--color-primary); }

  .suggestions-loading {
    text-align: center;
    padding: 24px;
    color: var(--color-text-tertiary);
    font-size: 0.875rem;
  }

  .done-step { padding: 20px 0; }
  .done-icon { text-align: center; margin-bottom: 12px; }

  .unfurl-row {
    display: flex;
    gap: var(--space-3);
    align-items: flex-start;
    margin-block-start: var(--space-5);
    padding: var(--space-4);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    text-align: left;
    cursor: pointer;
  }

  .unfurl-row input[type="checkbox"] {
    margin-block-start: 4px;
    flex-shrink: 0;
  }

  .unfurl-body {
    flex: 1;
    min-width: 0;
  }

  .unfurl-label {
    display: block;
    font-weight: 600;
    color: var(--color-text);
    margin-block-end: var(--space-1);
  }

  .unfurl-desc {
    display: block;
    font-size: var(--text-sm);
    color: var(--color-text-tertiary);
    line-height: 1.4;
  }

  .onboarding-actions {
    display: flex;
    justify-content: space-between;
    margin-top: 24px;
  }

  .skip-btn {
    padding: 10px 20px;
    background: none;
    border: none;
    color: var(--color-text-secondary);
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
  }

  .skip-btn:hover { color: var(--color-text); }

  .next-btn {
    padding: 10px 28px;
    background: var(--color-primary);
    color: white;
    border: none;
    border-radius: 9999px;
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
    transition: opacity 150ms ease;
  }

  .next-btn:hover { opacity: 0.9; }
  .next-btn:disabled,
  .skip-btn:disabled { opacity: 0.6; cursor: not-allowed; }

  .save-error {
    margin-top: 4px;
    font-size: 0.8125rem;
    color: var(--color-danger);
    text-align: center;
  }
</style>
