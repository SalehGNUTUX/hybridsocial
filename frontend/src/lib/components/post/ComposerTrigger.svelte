<script lang="ts">
  // Facebook-style "Write something..." pill — replaces the old
  // call-to-action button at the top of group / page feeds. Looks
  // like a text input but is in fact a single button: focus / click
  // dispatches the same `open-composer` event the rest of the app
  // uses, with the caller-supplied scope (group_id / page_id) so the
  // post lands where the user expects.

  import { currentUser } from '$lib/stores/auth.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import { t } from '$lib/stores/i18n.js';

  let {
    placeholder = '',
    groupId = null,
    pageId = null,
    contextLabel = '',
  }: {
    placeholder?: string;
    groupId?: string | null;
    pageId?: string | null;
    contextLabel?: string;
  } = $props();

  let effectivePlaceholder = $derived(placeholder || $t('composer.trigger_placeholder'));

  function open() {
    const detail: Record<string, unknown> = { contextLabel };
    if (groupId) detail.groupId = groupId;
    if (pageId) detail.pageId = pageId;
    window.dispatchEvent(new CustomEvent('open-composer', { detail }));
  }

  function handleKey(e: KeyboardEvent) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      open();
    }
  }
</script>

<button
  type="button"
  class="composer-trigger"
  onclick={open}
  onkeydown={handleKey}
  aria-label={contextLabel || effectivePlaceholder}
>
  <div class="composer-trigger-avatar">
    <Avatar
      src={$currentUser?.avatar_url ?? null}
      name={$currentUser?.display_name || $currentUser?.handle || $t('composer.you')}
      size="md"
    />
  </div>
  <span class="composer-trigger-placeholder">{effectivePlaceholder}</span>
</button>

<style>
  .composer-trigger {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    width: 100%;
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-full);
    cursor: text;
    font: inherit;
    color: var(--color-text-tertiary);
    text-align: start;
    transition: background var(--transition-fast), border-color var(--transition-fast);
    margin-block-end: var(--space-3);
  }

  .composer-trigger:hover,
  .composer-trigger:focus-visible {
    background: var(--color-surface-raised);
    border-color: var(--color-primary);
    color: var(--color-text-secondary);
    outline: none;
  }

  .composer-trigger-avatar {
    flex-shrink: 0;
  }

  .composer-trigger-placeholder {
    flex: 1;
    font-size: var(--text-sm);
    /* Look like placeholder text inside a real input so the affordance
       reads as "click here to type" rather than "click here to do
       something". */
    color: inherit;
  }
</style>
