import type { LayoutServerLoad } from './$types';
import { env } from '$env/dynamic/private';

// Fetch the public instance info at SSR time so the root layout can render
// real <meta name="description"> / og: tags into the initial HTML. Social
// crawlers (Twitter/Slack/Discord/Facebook) don't run JS, so these must be
// server-rendered, not applied client-side.
//
// Uses the internal backend URL (Docker network) rather than a relative
// path, which would hairpin out through the public edge during SSR. Falls
// back gracefully to no instance data if the backend is unreachable.
export const load: LayoutServerLoad = async ({ fetch }) => {
  const base = env.INTERNAL_API_URL || 'http://backend:4000';

  try {
    const res = await fetch(`${base}/api/v1/instance`);
    if (!res.ok) return { instance: null };

    const info = (await res.json()) as Record<string, unknown>;
    const theme = (info.theme as Record<string, unknown> | null) ?? null;

    return {
      instance: {
        title: (info.title as string) || 'HybridSocial',
        description:
          (info.short_description as string) || (info.description as string) || '',
        favicon_url:
          (info.favicon_url as string) || (theme?.favicon_url as string) || null,
        og_image_url:
          (info.og_image_url as string) || (theme?.og_image_url as string) || null
      }
    };
  } catch {
    return { instance: null };
  }
};
