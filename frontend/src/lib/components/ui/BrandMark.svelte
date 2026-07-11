<script lang="ts">
  // The instance brand mark, shared by the auth (login/register/reset),
  // hero, and legal chrome. Renders the admin-configured logo when set,
  // otherwise a rounded-square fallback with the instance's initial.
  //
  // The logo is uploaded in the admin panel under Instance ›
  // Appearance & branding (Logo, light + dark). This mirrors the header's
  // selection logic so the mark is consistent everywhere.
  import { themeStore, resolvedMode } from '$lib/stores/theme.js';
  import { instanceName } from '$lib/stores/instance.js';

  let { size = 40 }: { size?: number } = $props();

  // Prefer the dark logo in dark mode; fall back to whichever is set.
  let logo = $derived(
    $resolvedMode === 'dark'
      ? $themeStore?.dark_logo_url || $themeStore?.logo_url
      : $themeStore?.logo_url || $themeStore?.dark_logo_url,
  );

  // Fallback glyph: the instance name's first character (was a hardcoded
  // "H"), so an un-branded instance still reads as itself.
  let initial = $derived(($instanceName?.trim()?.[0] || 'H').toUpperCase());
</script>

{#if logo}
  <img src={logo} alt={$instanceName} class="brand-mark-img" style="height: {size}px" />
{:else}
  <svg width={size} height={size} viewBox="0 0 28 28" fill="none" aria-hidden="true">
    <rect rx="6" width="28" height="28" fill="var(--color-primary)" />
    <text
      x="14"
      y="19.5"
      text-anchor="middle"
      fill="white"
      font-size="15"
      font-weight="700">{initial}</text>
  </svg>
{/if}

<style>
  .brand-mark-img {
    width: auto;
    max-width: 100%;
    object-fit: contain;
    display: block;
  }
</style>
