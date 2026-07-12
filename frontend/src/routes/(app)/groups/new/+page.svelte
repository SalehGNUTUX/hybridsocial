<script lang="ts">
  import { instanceName } from '$lib/stores/instance.js';
  import { goto } from '$app/navigation';
  import { createGroup, type FederationMode } from '$lib/api/groups.js';

  let name = $state('');
  let description = $state('');
  let visibility = $state<'public' | 'private'>('public');
  // Backend join_policy enum: :open | :approval | :invite_only (| :screening,
  // configured later via the settings Screening tab).
  let joinPolicy = $state<'open' | 'approval' | 'invite_only'>('open');
  let federationMode = $state<FederationMode>('local_only');
  let submitting = $state(false);
  let error = $state('');

  let canSubmit = $derived(name.trim().length > 0 && !submitting);

  async function submit() {
    if (!canSubmit) return;
    submitting = true;
    error = '';
    try {
      const group = await createGroup({
        name: name.trim(),
        description: description.trim() || undefined,
        visibility,
        join_policy: joinPolicy,
        federation_mode: federationMode,
      });
      goto(`/groups/${group.id}`);
    } catch (e: unknown) {
      // The backend slugifies the group's name into the federated
      // actor handle, so a name that collides with another group or
      // user surfaces as a `details.handle: ["has already been taken"]`
      // validation error. Translate that into something the user can
      // act on — they don't see "handle" in this form.
      const body = (e as { body?: { details?: Record<string, string[]>; message?: string } })?.body;
      const handleErrs = body?.details?.handle;
      if (handleErrs?.some((m) => /taken|exist|use|unique/i.test(m))) {
        error = 'A group or account is already using a similar name. Please choose a different name.';
      } else if (handleErrs?.length) {
        error = `Name: ${handleErrs[0]}`;
      } else if (body?.message) {
        error = body.message;
      } else {
        error = e instanceof Error ? e.message : 'Failed to create group.';
      }
    } finally {
      submitting = false;
    }
  }
</script>

<svelte:head>
  <title>New group — {$instanceName}</title>
</svelte:head>

<div class="new-group-page">
  <div class="page-header">
    <h1 class="page-title">Create a group</h1>
    <p class="page-sub">Start a community or a private space. Your choices below shape how the group works for its lifetime.</p>
  </div>

  {#if error}
    <div class="error" role="alert">{error}</div>
  {/if}

  <form onsubmit={(e) => { e.preventDefault(); submit(); }}>
    <div class="field">
      <label for="group-name">Name</label>
      <input
        id="group-name"
        type="text"
        bind:value={name}
        maxlength="100"
        placeholder="e.g. Morning runners of Cairo"
        required
      />
    </div>

    <div class="field">
      <label for="group-desc">Description (optional)</label>
      <textarea
        id="group-desc"
        bind:value={description}
        maxlength="1200"
        rows="3"
        placeholder="What is this group about?"
      ></textarea>
    </div>

    <div class="field">
      <label for="group-visibility">Visibility</label>
      <select id="group-visibility" bind:value={visibility}>
        <option value="public">Public — anyone on this instance can find and view it</option>
        <option value="private">Private — only members can view its posts</option>
      </select>
    </div>

    <div class="field">
      <label for="group-join">Who can join</label>
      <select id="group-join" bind:value={joinPolicy}>
        <option value="open">Open — anyone can join instantly</option>
        <option value="approval">Request to join — an admin approves each member</option>
        <option value="invite_only">Invite only — members join by invitation</option>
      </select>
      <p class="field-hint">You can add screening questions later from the group's settings.</p>
    </div>

    <fieldset class="mode-picker">
      <legend>Group type — this choice is permanent</legend>
      <p class="mode-sub">
        You cannot change this after the group is created. Switching later
        would either expose private posts to remote followers or abandon
        remote followers mid-subscription.
      </p>

      <label class="mode-option" class:selected={federationMode === 'local_only'}>
        <input
          type="radio"
          name="federation_mode"
          value="local_only"
          checked={federationMode === 'local_only'}
          onchange={() => { federationMode = 'local_only'; }}
        />
        <div class="mode-body">
          <div class="mode-title">Local-only</div>
          <p class="mode-desc">
            Only members on this instance can see and post. You control
            membership, screening, and moderation. The group does not appear
            anywhere else in the fediverse.
          </p>
          <div class="mode-best-for"><strong>Best for:</strong> friend groups, private communities, trusted circles.</div>
        </div>
      </label>

      <label class="mode-option" class:selected={federationMode === 'public_federated'}>
        <input
          type="radio"
          name="federation_mode"
          value="public_federated"
          checked={federationMode === 'public_federated'}
          onchange={() => { federationMode = 'public_federated'; }}
        />
        <div class="mode-body">
          <div class="mode-title">
            Public federated
            <span class="pill">Federation coming soon</span>
          </div>
          <p class="mode-desc">
            Anyone across the fediverse can follow and see posts. Membership
            is follow-based — you can't screen new members or make the group
            private later.
          </p>
          <div class="mode-best-for"><strong>Best for:</strong> public communities, topic hubs, broad discussion.</div>
          <div class="mode-note">
            Note: federation delivery is not wired yet. The group will work
            as a public local group for now, and your choice is remembered
            so federation will just start working once it ships.
          </div>
        </div>
      </label>
    </fieldset>

    <div class="actions">
      <button type="button" class="btn btn-ghost" onclick={() => goto('/groups')}>Cancel</button>
      <button type="submit" class="btn btn-primary" disabled={!canSubmit}>
        {submitting ? 'Creating…' : 'Create group'}
      </button>
    </div>
  </form>
</div>

<style>
  .new-group-page {
    max-width: 640px;
    margin: 0 auto;
    padding-block-end: var(--space-8);
  }

  .page-header {
    margin-block-end: var(--space-6);
  }

  .page-title {
    font-size: var(--text-xl);
    font-weight: 700;
    color: var(--color-text);
  }

  .page-sub {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    margin-block-start: var(--space-1);
  }

  .error {
    background: var(--color-danger-surface, #fee);
    color: var(--color-danger, #b00);
    border: 1px solid var(--color-danger, #b00);
    border-radius: var(--radius-md);
    padding: var(--space-3);
    margin-block-end: var(--space-4);
    font-size: var(--text-sm);
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    margin-block-end: var(--space-5);
  }

  .field label {
    font-weight: 600;
    color: var(--color-text);
  }

  .field input,
  .field textarea,
  .field select {
    padding: var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface);
    color: var(--color-text);
    font: inherit;
  }

  .field textarea {
    resize: vertical;
  }

  .field-hint {
    margin: 0;
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .mode-picker {
    border: none;
    padding: 0;
    margin: 0 0 var(--space-6) 0;
  }

  .mode-picker legend {
    font-weight: 700;
    color: var(--color-text);
    padding: 0;
    margin-block-end: var(--space-2);
  }

  .mode-sub {
    font-size: var(--text-sm);
    color: var(--color-warning, #b87a00);
    margin-block-end: var(--space-4);
  }

  .mode-option {
    display: flex;
    gap: var(--space-3);
    padding: var(--space-4);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    cursor: pointer;
    transition: border-color 150ms ease, background-color 150ms ease;
    margin-block-end: var(--space-3);
  }

  .mode-option:hover {
    background: var(--color-surface-hover);
  }

  .mode-option.selected {
    border-color: var(--color-primary);
    background: var(--color-primary-subtle, rgba(0,0,0,0.03));
  }

  .mode-option input[type="radio"] {
    margin-block-start: 4px;
    flex-shrink: 0;
  }

  .mode-body {
    flex: 1;
    min-width: 0;
  }

  .mode-title {
    font-weight: 700;
    color: var(--color-text);
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-wrap: wrap;
  }

  .pill {
    display: inline-block;
    background: var(--color-surface-alt, rgba(0,0,0,0.05));
    color: var(--color-text-tertiary);
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 9999px;
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }

  .mode-desc {
    font-size: var(--text-sm);
    color: var(--color-text);
    margin: var(--space-2) 0 var(--space-3);
  }

  .mode-best-for {
    font-size: var(--text-sm);
    color: var(--color-text-tertiary);
  }

  .mode-note {
    margin-block-start: var(--space-3);
    padding: var(--space-2) var(--space-3);
    background: var(--color-surface-alt, rgba(0,0,0,0.04));
    border-radius: var(--radius-md);
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .actions {
    display: flex;
    gap: var(--space-3);
    justify-content: flex-end;
  }
</style>
