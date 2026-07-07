<script lang="ts">
  import { renderCustomEmojis, type CustomEmoji } from '$lib/utils/custom-emoji.js';

  // Renders a user's name with custom emojis: `:shortcode:` in the name is
  // swapped for the matching <img> from `emojis`. The name is plain,
  // user-controlled text, so it is HTML-escaped BEFORE emoji substitution —
  // renderCustomEmojis only injects <img> for known shortcodes and leaves
  // the (now-escaped) surrounding text alone, so the {@html} is safe.
  let {
    name,
    emojis = undefined,
    fallback = '',
  }: {
    name?: string | null;
    emojis?: CustomEmoji[];
    fallback?: string;
  } = $props();

  function escapeHtml(value: string): string {
    return value
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  const text = $derived((name ?? '').trim() || fallback);
  const html = $derived(renderCustomEmojis(escapeHtml(text), emojis));
</script>

<span class="display-name">{@html html}</span>

<style>
  .display-name {
    /* Inline so emoji <img> sit on the text baseline with the name. */
    display: inline;
  }
</style>
