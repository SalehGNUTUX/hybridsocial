// Recognize the public YouTube URL shapes we want to embed:
//   https://www.youtube.com/watch?v=ID
//   https://youtube.com/watch?v=ID
//   https://m.youtube.com/watch?v=ID
//   https://youtu.be/ID
//   https://www.youtube.com/shorts/ID
//   https://www.youtube.com/embed/ID
//   https://www.youtube.com/live/ID
//   https://www.youtube.com/playlist?list=PLID
//   https://www.youtube.com/watch?v=ID&list=PLID  (video that opens inside a playlist)
// Returns the 11-char video ID (when present), an optional playlist
// id, and an optional `t=` start offset. Playlist refs without a
// video ID still embed via YouTube's `/embed/videoseries` endpoint;
// when both are present the embed plays the named video and shows
// the rest of the playlist in YouTube's built-in side rail.

export interface YouTubeRef {
  id?: string;
  list?: string;
  start?: number;
}

const ID_RE = /^[A-Za-z0-9_-]{11}$/;
// Playlist IDs come in two shapes: real lists ("PL"/"UU"/"LL"/"OL"/
// "FL"/"RDxxx") which are 13–34 chars, and auto-mix IDs ("RD",
// "RDMM", "RDCLAK") that can be shorter. We accept any reasonable
// length and the URL-safe alphabet — the player itself validates;
// we just need to keep junk like ";rel=" out.
const LIST_RE = /^[A-Za-z0-9_-]{10,42}$/;

function parseStart(value: string | null): number | undefined {
  if (!value) return undefined;
  // YouTube accepts both "90" and "1m30s".
  if (/^\d+$/.test(value)) {
    const n = parseInt(value, 10);
    return n > 0 ? n : undefined;
  }
  const m = value.match(/^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/);
  if (!m) return undefined;
  const [, h, mm, s] = m;
  const total = (parseInt(h ?? '0', 10) * 3600) + (parseInt(mm ?? '0', 10) * 60) + parseInt(s ?? '0', 10);
  return total > 0 ? total : undefined;
}

export function parseYouTubeUrl(raw: string): YouTubeRef | null {
  if (!raw || typeof raw !== 'string') return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  const host = url.hostname.replace(/^www\./, '').toLowerCase();
  const start = parseStart(url.searchParams.get('t') ?? url.searchParams.get('start'));
  const listRaw = url.searchParams.get('list');
  const list = listRaw && LIST_RE.test(listRaw) ? listRaw : undefined;

  if (host === 'youtu.be') {
    const id = url.pathname.replace(/^\//, '').split('/')[0];
    return ID_RE.test(id) ? { id, list, start } : null;
  }

  if (host === 'youtube.com' || host === 'm.youtube.com' || host === 'music.youtube.com') {
    if (url.pathname === '/watch') {
      const id = url.searchParams.get('v') ?? '';
      if (ID_RE.test(id)) return { id, list, start };
      // Some share URLs carry the v= but it's blank and only `list=`
      // matters (rare, but YouTube does this with playlist-only
      // links pasted from the app). Fall through to playlist-only.
    }
    if (url.pathname === '/playlist' && list) {
      return { list, start };
    }
    const m = url.pathname.match(/^\/(?:embed|shorts|live|v)\/([^/?#]+)/);
    if (m && ID_RE.test(m[1])) return { id: m[1], list, start };
    // Bare /playlist?list=… with a list we accepted above is handled,
    // but URLs like /embed/videoseries?list=PLID land here.
    if (url.pathname === '/embed/videoseries' && list) {
      return { list, start };
    }
  }

  return null;
}

// Scan free-form post content (HTML or plain) for the first YouTube
// URL. We only need the first one — link previews are single-card.
export function findYouTubeInContent(content: string | null | undefined): YouTubeRef | null {
  if (!content) return null;
  const matches = content.match(/https?:\/\/[^\s<>"'`]+/g);
  if (!matches) return null;
  for (const candidate of matches) {
    const ref = parseYouTubeUrl(candidate);
    if (ref) return ref;
  }
  return null;
}

export function youtubeThumbnail(id: string): string {
  return `https://i.ytimg.com/vi/${id}/hqdefault.jpg`;
}

export function youtubeEmbedUrl(ref: YouTubeRef): string {
  // `enablejsapi=1` lets us postMessage commands (pauseVideo) to the
  // embed when it scrolls out of view; without it the iframe ignores
  // every command. `origin` is required by YouTube's API to bind the
  // command channel to our window — only set in browser contexts so
  // SSR doesn't reach for `location`.
  const params = new URLSearchParams({
    autoplay: '1',
    rel: '0',
    modestbranding: '1',
    enablejsapi: '1',
  });
  if (ref.start && ref.start > 0) params.set('start', String(ref.start));
  // When a playlist is attached, YouTube's embed adds the built-in
  // scrollable playlist side-rail with all videos inside the iframe —
  // no API key, no custom UI, the user can pick any track. Works for
  // both "video that's inside a playlist" and "playlist-only" links.
  if (ref.list) params.set('list', ref.list);
  if (typeof window !== 'undefined' && window.location) {
    params.set('origin', window.location.origin);
  }
  // `/embed/videoseries` is YouTube's dedicated entry point for
  // playlist-only embeds (no leading video). When we have a video id
  // we use the normal /embed/<id> route, which still honors `list=`.
  const path = ref.id ? `embed/${ref.id}` : 'embed/videoseries';
  return `https://www.youtube-nocookie.com/${path}?${params.toString()}`;
}

export function youtubeWatchUrl(ref: YouTubeRef): string {
  if (ref.id) {
    const p = new URLSearchParams({ v: ref.id });
    if (ref.list) p.set('list', ref.list);
    if (ref.start && ref.start > 0) p.set('t', `${ref.start}s`);
    return `https://www.youtube.com/watch?${p.toString()}`;
  }
  if (ref.list) {
    return `https://www.youtube.com/playlist?list=${ref.list}`;
  }
  return 'https://www.youtube.com/';
}
