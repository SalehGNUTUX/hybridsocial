import { derived } from 'svelte/store';
import { page } from '$app/stores';

// The instance's admin-configured display name, sourced from the public
// instance config (loaded once in the root +layout.server.ts and exposed
// on page.data.instance). NOTHING instance-specific is hardcoded — the
// ONLY hardcoded brand allowed anywhere is the software product name,
// "HybridSocial", used purely as a fallback when the operator hasn't set
// an instance name yet.
export const instanceName = derived(
  page,
  ($page) => ((($page.data as Record<string, unknown>)?.instance as { title?: string } | undefined)?.title || 'HybridSocial')
);
