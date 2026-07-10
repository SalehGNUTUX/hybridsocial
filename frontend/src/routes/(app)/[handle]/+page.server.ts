import type { PageServerLoad } from './$types';
import { env } from '$env/dynamic/private';

// SSR a profile's share metadata. Privacy-aware on the backend: only
// profiles that allow unfurling expose name/bio/avatar; locked/private
// (and suspended/deleted) profiles get a neutral placeholder so nothing
// leaks. Rendered by the root layout via page.data.og.
export const load: PageServerLoad = async ({ params, fetch }) => {
  const base = env.INTERNAL_API_URL || 'http://backend:4000';
  const handle = params.handle.replace(/^@/, '');

  try {
    const res = await fetch(`${base}/api/v1/og/profile/${encodeURIComponent(handle)}`);
    if (!res.ok) return {};

    const m = (await res.json()) as Record<string, string>;
    return {
      og: {
        title: m.title,
        description: m.description,
        image: m.image,
        type: m.type || 'profile',
        url: m.url
      }
    };
  } catch {
    return {};
  }
};
