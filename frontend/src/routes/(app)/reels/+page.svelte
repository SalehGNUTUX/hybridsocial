<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client.js';
  import type { Post, MediaAttachment } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import PostActions from '$lib/components/post/PostActions.svelte';
  import { instanceName } from '$lib/stores/instance.js';

  let posts = $state<Post[]>([]);
  let loading = $state(true);
  let error = $state('');

  // Reels autoplay by default (the whole point of the format); still
  // toggleable and remembered across visits.
  const AUTOPLAY_KEY = 'hs-reels-autoplay';
  let autoplay = $state(true);

  function toggleAutoplay() {
    autoplay = !autoplay;
    try {
      localStorage.setItem(AUTOPLAY_KEY, autoplay ? '1' : '0');
    } catch {
      /* storage unavailable — the toggle just won't persist */
    }
  }

  // A reel is a portrait (≈9:16) video. When the federated media has no
  // dimensions we keep it rather than drop it, so the feed isn't empty.
  function reelVideo(post: Post): MediaAttachment | undefined {
    const v = post.media_attachments?.find((m) => m.type === 'video');
    if (!v) return undefined;
    const o = (v.meta?.original ?? {}) as { width?: number; height?: number };
    if (o.width && o.height && o.height <= o.width) return undefined;
    return v;
  }

  let reels = $derived(posts.filter((p) => reelVideo(p)));

  function videoPoster(m: MediaAttachment): string | undefined {
    if (!m.preview_url || m.preview_url === m.url) return undefined;
    return m.preview_url;
  }

  function firstFrameSrc(url: string): string {
    return url.includes('#') ? url : `${url}#t=0.1`;
  }

  const viewsReported = new Set<string>();

  async function reportView(
    postId: string,
    watchDuration: number,
    totalDuration: number,
    completed: boolean,
    replayed: boolean,
  ) {
    try {
      await api.post(`/api/v1/statuses/${postId}/view`, {
        watch_duration: watchDuration,
        total_duration: totalDuration,
        completed,
        replayed,
        source: 'reels_feed',
      });
    } catch {
      // Best-effort — never block playback on view reporting.
    }
  }

  function handlePlay(postId: string, event: Event) {
    if (viewsReported.has(postId)) return;
    viewsReported.add(postId);
    const video = event.currentTarget as HTMLVideoElement;
    reportView(postId, 0, video.duration || 0, false, false);
  }

  function handleEnded(postId: string, event: Event) {
    const video = event.currentTarget as HTMLVideoElement;
    const duration = video.duration || 0;
    const replayed = viewsReported.has(`${postId}:ended`);
    viewsReported.add(`${postId}:ended`);
    reportView(postId, duration, duration, true, replayed);
  }

  async function loadReels() {
    loading = true;
    error = '';
    try {
      const result = await api.get<any>('/api/v1/timelines/streams');
      const data = Array.isArray(result) ? result : (result as any)?.data || [];
      posts = data;
    } catch {
      error = 'Failed to load reels.';
    } finally {
      loading = false;
    }
  }

  onMount(() => {
    try {
      const v = localStorage.getItem(AUTOPLAY_KEY);
      if (v !== null) autoplay = v === '1';
    } catch {
      /* ignore */
    }
    loadReels();
  });

  // Play the reel (muted) once it's mostly in view; pause when scrolled away.
  // The autoplay flag is passed reactively so toggling updates mounted reels.
  function reelAutoplay(node: HTMLVideoElement, enabled: boolean) {
    let auto = enabled;
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const ratio = entry.intersectionRatio;
          if (entry.isIntersecting && ratio >= 0.25 && node.preload === 'none') {
            node.preload = 'metadata';
          }
          if (!entry.isIntersecting || ratio < 0.25) {
            if (!node.paused) node.pause();
          } else if (auto && ratio >= 0.6) {
            node.muted = true;
            node.play().catch(() => {});
          }
        }
      },
      { threshold: [0, 0.25, 0.6] },
    );
    io.observe(node);
    return {
      update(next: boolean) {
        auto = next;
        if (!auto && !node.paused) node.pause();
      },
      destroy: () => io.disconnect(),
    };
  }
</script>

<svelte:head>
  <title>Reels - {$instanceName}</title>
</svelte:head>

<div class="reels-page">
  <div class="page-header">
    <h1 class="page-title">Reels</h1>
    <button
      type="button"
      class="autoplay-toggle"
      class:on={autoplay}
      role="switch"
      aria-checked={autoplay}
      onclick={toggleAutoplay}
    >
      <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5v14l11-7z" /></svg>
      Autoplay
    </button>
  </div>

  {#if loading}
    <div class="reels-feed" aria-hidden="true">
      <div class="reel skeleton"></div>
    </div>
  {:else if error}
    <div class="state">
      <p class="state-text">{error}</p>
      <button type="button" class="btn btn-outline" onclick={loadReels}>Retry</button>
    </div>
  {:else if reels.length === 0}
    <div class="state">
      <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="var(--color-text-tertiary)" stroke-width="1.5" aria-hidden="true">
        <rect x="3" y="5" width="18" height="14" rx="2" /><path d="M10 13l4 2-4 2z" /><path d="M8 5v4M13 5v4M18 5v4" />
      </svg>
      <p class="state-text">No reels yet</p>
      <p class="state-sub">Vertical (9:16) videos will appear here.</p>
    </div>
  {:else}
    <div class="reels-feed">
      {#each reels as post (post.id)}
        {@const v = reelVideo(post)}
        <section class="reel">
          {#if v}
            <video
              src={firstFrameSrc(v.url)}
              poster={videoPoster(v)}
              controls
              playsinline
              preload="none"
              class="reel-video"
              aria-label={v.description || 'Reel'}
              use:reelAutoplay={autoplay}
              onplay={(e) => handlePlay(post.id, e)}
              onended={(e) => handleEnded(post.id, e)}
            >
              <track kind="captions" />
            </video>
          {/if}
          <div class="reel-overlay">
            <a href="/@{post.account.handle}" class="reel-author">
              <Avatar src={post.account.avatar_url} name={post.account.display_name || post.account.handle} size="sm" />
              <span class="reel-author-name">{post.account.display_name || post.account.handle}</span>
            </a>
            {#if post.content}
              <p class="reel-caption" dir="auto">{post.content}</p>
            {/if}
            <div class="reel-actions">
              <PostActions {post} />
            </div>
          </div>
        </section>
      {/each}
    </div>
  {/if}
</div>

<style>
  .reels-page {
    display: flex;
    flex-direction: column;
    height: calc(100dvh - var(--header-height, 60px));
  }

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    padding-block: var(--space-3);
  }

  .page-title {
    font-size: var(--text-xl);
    font-weight: 700;
    color: var(--color-text);
    margin: 0;
  }

  .autoplay-toggle {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    padding: var(--space-1) var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-full);
    background: transparent;
    color: var(--color-text-secondary);
    font-size: var(--text-sm);
    font-weight: 500;
    cursor: pointer;
    transition: background 150ms ease, color 150ms ease, border-color 150ms ease;
  }

  .autoplay-toggle:hover {
    color: var(--color-text);
    border-color: var(--color-text-tertiary);
  }

  .autoplay-toggle.on {
    background: var(--color-primary-soft, rgba(var(--color-primary-rgb), 0.12));
    color: var(--color-primary);
    border-color: transparent;
  }

  /* Vertical, snap-scrolling reels feed. */
  .reels-feed {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    scroll-snap-type: y mandatory;
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    scrollbar-width: none;
  }

  .reels-feed::-webkit-scrollbar {
    display: none;
  }

  .reel {
    position: relative;
    flex: 0 0 100%;
    height: 100%;
    scroll-snap-align: center;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  /* 9:16 frame, filled edge-to-edge (object-fit: cover) so a portrait reel
     shows at its true framing with no letterbox/pillarbox black bars. */
  .reel-video {
    height: 100%;
    max-height: 100%;
    aspect-ratio: 9 / 16;
    max-width: 100%;
    object-fit: cover;
    background: #000;
    border-radius: var(--radius-lg);
  }

  .reel.skeleton {
    background: var(--color-surface-container);
    border-radius: var(--radius-lg);
  }

  /* Info + actions sit over the bottom of the reel on a legibility scrim. */
  .reel-overlay {
    position: absolute;
    inset-inline: 50%;
    bottom: 0;
    transform: translateX(-50%);
    width: min(100%, calc(100% * 9 / 16 * 1));
    max-width: 100%;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-8) var(--space-3) var(--space-3);
    background: linear-gradient(to top, rgba(0, 0, 0, 0.6), transparent);
    border-radius: 0 0 var(--radius-lg) var(--radius-lg);
    pointer-events: none;
  }

  .reel-overlay > * {
    pointer-events: auto;
  }

  .reel-author {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    color: #fff;
    text-decoration: none;
    font-weight: 600;
    width: fit-content;
  }

  .reel-author-name {
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.6);
  }

  .reel-caption {
    margin: 0;
    color: #fff;
    font-size: var(--text-sm);
    line-height: 1.4;
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.6);
    display: -webkit-box;
    -webkit-line-clamp: 3;
    line-clamp: 3;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .reel-actions {
    /* Give the reused action bar a translucent surface so it reads over the
       video without restyling PostActions itself. */
    background: var(--color-surface-raised);
    border-radius: var(--radius-full);
    padding-inline: var(--space-1);
  }

  .state {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: var(--space-2);
    text-align: center;
  }

  .state-text {
    color: var(--color-text);
    font-weight: 600;
    margin: 0;
  }

  .state-sub {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    margin: 0;
  }

  .btn-outline {
    display: inline-flex;
    align-items: center;
    padding: var(--space-2) var(--space-3);
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    color: var(--color-text-secondary);
    cursor: pointer;
    font: inherit;
    font-size: var(--text-sm);
  }
</style>
