<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client.js';
  import type { Post, MediaAttachment } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import { instanceName } from '$lib/stores/instance.js';

  let posts: Post[] = $state([]);
  let loading = $state(true);
  let error = $state('');

  // Per-post description open/closed. Descriptions are hidden in the feed
  // by default and only revealed when the viewer opens one (collapsible on
  // click/tap), so a card stays a video-first card.
  let expanded = $state<Record<string, boolean>>({});

  // Autoplay is opt-in and remembered across visits. When on, a stream plays
  // (muted) once it's mostly in view and pauses when scrolled past.
  const AUTOPLAY_KEY = 'hs-streams-autoplay';
  let autoplay = $state(false);

  function toggleAutoplay() {
    autoplay = !autoplay;
    try {
      localStorage.setItem(AUTOPLAY_KEY, autoplay ? '1' : '0');
    } catch {
      /* storage unavailable — the toggle just won't persist */
    }
  }

  // Track which posts we've already reported a view for so we don't
  // double-count the initial `play` event.
  const viewsReported = new Set<string>();

  // Reserve the video box with the real aspect ratio (from media meta,
  // falling back to 16:9) so a not-yet-loaded video shows a proper frame
  // instead of collapsing to a thin controls bar.
  function videoAspect(m: MediaAttachment): string {
    const o = (m.meta?.original ?? {}) as { width?: number; height?: number };
    return o.width && o.height ? `${o.width} / ${o.height}` : '16 / 9';
  }

  // preview_url falls back to the *video* URL for federated videos, which
  // isn't a valid poster image and actually blocks the browser from
  // painting the first frame. Only use it when it's a distinct thumbnail.
  function videoPoster(m: MediaAttachment): string | undefined {
    if (!m.preview_url || m.preview_url === m.url) return undefined;
    return m.preview_url;
  }

  // A #t media fragment makes the browser seek to (and paint) that frame
  // as a thumbnail once metadata loads — lazily, via the intersection
  // observer below — so the feed shows first frames instead of blank boxes.
  function firstFrameSrc(url: string): string {
    return url.includes('#') ? url : `${url}#t=0.1`;
  }

  function toggleExpand(id: string) {
    expanded = { ...expanded, [id]: !expanded[id] };
  }

  async function loadStreams() {
    loading = true;
    error = '';
    try {
      const result = await api.get<any>('/api/v1/timelines/streams');
      const data = Array.isArray(result) ? result : (result as any)?.data || [];
      posts = data;
    } catch {
      error = 'Failed to load streams.';
    } finally {
      loading = false;
    }
  }

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
        source: 'streams_feed',
      });
    } catch {
      // View reporting is best-effort — never block playback on it.
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

  onMount(() => {
    try {
      autoplay = localStorage.getItem(AUTOPLAY_KEY) === '1';
    } catch {
      /* ignore */
    }
    loadStreams();
  });

  // Loads metadata as a card nears the viewport, pauses playback when it
  // scrolls away, and — when autoplay is enabled — plays it (muted) once it's
  // mostly in view. The autoplay flag is passed reactively via the action
  // parameter, so toggling it takes effect on already-mounted videos.
  function lazyVideo(node: HTMLVideoElement, enabled: boolean) {
    let auto = enabled;
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const ratio = entry.intersectionRatio;
          if (entry.isIntersecting && ratio >= 0.25 && node.preload === 'none') {
            node.preload = 'metadata';
          }
          if (!entry.isIntersecting || ratio < 0.25) {
            // Off-screen — pause so audio never plays out of view.
            if (!node.paused) node.pause();
          } else if (auto && ratio >= 0.6) {
            // Mostly in view and autoplay is on — play muted (autoplay policy
            // blocks sound; the viewer can unmute via the native controls).
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
  <title>Streams - {$instanceName}</title>
</svelte:head>

<div class="streams-page">
  <div class="page-header">
    <h1 class="page-title">Streams</h1>
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
    <div class="streams-feed" aria-hidden="true">
      {#each Array(2) as _, i (i)}
        <div class="stream-card">
          <div class="skel-video"></div>
          <div class="skel-body">
            <div class="skel-line skel-line-lg"></div>
            <div class="skel-line skel-line-sm"></div>
          </div>
        </div>
      {/each}
    </div>
  {:else if error}
    <div class="error-state">
      <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="var(--color-text-tertiary)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <circle cx="12" cy="12" r="10" /><line x1="12" y1="8" x2="12" y2="12" /><line x1="12" y1="16" x2="12.01" y2="16" />
      </svg>
      <p class="empty-text">{error}</p>
      <button type="button" class="btn btn-outline" onclick={loadStreams}>Retry</button>
    </div>
  {:else if posts.length === 0}
    <div class="empty-state">
      <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="var(--color-text-tertiary)" stroke-width="1.5" aria-hidden="true">
        <polygon points="5 3 19 12 5 21 5 3"/>
      </svg>
      <p class="empty-text">No streams yet</p>
      <p class="empty-sub">Video streams will appear here.</p>
    </div>
  {:else}
    <div class="streams-feed">
      {#each posts as post (post.id)}
        {@const videoAttachment = post.media_attachments?.find((m) => m.type === 'video')}
        <div class="stream-card">
          {#if videoAttachment}
            <div class="stream-video-wrapper" style="aspect-ratio: {videoAspect(videoAttachment)}">
              <video
                src={firstFrameSrc(videoAttachment.url)}
                poster={videoPoster(videoAttachment)}
                controls
                playsinline
                preload="none"
                class="stream-video"
                aria-label={videoAttachment.description || 'Video stream'}
                use:lazyVideo={autoplay}
                onplay={(e) => handlePlay(post.id, e)}
                onended={(e) => handleEnded(post.id, e)}
              >
                <track kind="captions" />
              </video>
              <div class="stream-overlay">
                <a href="/@{post.account.handle}" class="stream-author">
                  <Avatar src={post.account.avatar_url} name={post.account.display_name || post.account.handle} size="sm" />
                  <span class="stream-author-name">{post.account.display_name || post.account.handle}</span>
                </a>
              </div>
            </div>
          {/if}
          {#if post.content_html || post.content}
            <div class="stream-caption">
              <button
                type="button"
                class="caption-toggle"
                aria-expanded={!!expanded[post.id]}
                aria-controls={`stream-desc-${post.id}`}
                onclick={() => toggleExpand(post.id)}
              >
                <svg
                  class="caption-chevron"
                  class:open={expanded[post.id]}
                  width="16" height="16" viewBox="0 0 24 24" fill="none"
                  stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
                  aria-hidden="true"
                >
                  <polyline points="6 9 12 15 18 9" />
                </svg>
                {expanded[post.id] ? 'Hide description' : 'Show description'}
              </button>
              {#if expanded[post.id]}
                <div id={`stream-desc-${post.id}`} class="stream-content">
                  {#if post.content_html}{@html post.content_html}{:else}<p>{post.content}</p>{/if}
                </div>
              {/if}
            </div>
          {/if}
          <div class="stream-actions">
            <a href="/post/{post.id}" class="stream-action-link">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>
              </svg>
              {post.reply_count > 0 ? `${post.reply_count} ` : ''}Comments
            </a>
            <span class="stream-stat">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                <circle cx="12" cy="12" r="10"/>
                <path d="M8 14s1.5 2 4 2 4-2 4-2"/>
                <line x1="9" y1="9" x2="9.01" y2="9"/>
                <line x1="15" y1="9" x2="15.01" y2="9"/>
              </svg>
              {post.reaction_count > 0 ? `${post.reaction_count} ` : ''}Reactions
            </span>
          </div>
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .streams-page {
    max-width: var(--feed-max-width);
    margin: 0 auto;
  }

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    margin-block-end: var(--space-4);
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

  .page-title {
    font-size: var(--text-xl);
    font-weight: 700;
    color: var(--color-text);
  }

  .error-state,
  .empty-state {
    text-align: center;
    padding: var(--space-16) var(--space-4);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-3);
  }

  .empty-text {
    font-size: var(--text-base);
    color: var(--color-text-tertiary);
  }

  .empty-sub {
    font-size: var(--text-sm);
    color: var(--color-text-tertiary);
  }

  .streams-feed {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .stream-card {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl);
    overflow: hidden;
  }

  .stream-video-wrapper {
    position: relative;
    width: 100%;
    background: #000;
    /* Reserve space so the card doesn't collapse to a controls bar
       before the video loads. aspect-ratio is set inline from media
       meta (fallback 16/9); max-height keeps tall portrait clips sane. */
    aspect-ratio: 16 / 9;
    max-height: 70vh;
  }

  .stream-video {
    width: 100%;
    height: 100%;
    object-fit: contain;
    display: block;
  }

  .stream-overlay {
    position: absolute;
    /* Sit at the TOP so it never covers the video's native controls
       (play/seek/volume) at the bottom. */
    inset-block-start: 0;
    inset-inline: 0;
    padding: var(--space-3) var(--space-4);
    background: linear-gradient(rgba(0, 0, 0, 0.7), transparent);
    /* Let clicks fall through to the <video> controls; only the author
       link re-enables pointer events. Without this the overlay swallowed
       every play/pause/seek tap. */
    pointer-events: none;
  }

  .stream-author {
    pointer-events: auto;
  }

  .stream-author {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    text-decoration: none;
    color: #fff;
  }

  .stream-author:hover {
    text-decoration: none;
  }

  .stream-author:focus-visible {
    outline: 2px solid #fff;
    outline-offset: 2px;
    border-radius: var(--radius-md);
  }

  .stream-author-name {
    font-size: var(--text-sm);
    font-weight: 600;
  }

  .stream-content {
    padding: 0 var(--space-4) var(--space-3);
    font-size: var(--text-sm);
    color: var(--color-text);
    line-height: var(--leading-relaxed);
    overflow-wrap: anywhere;
  }

  /* The description is collapsed by default — only this toggle shows under
     the video. Tapping it reveals the (collapsible) description. */
  .caption-toggle {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    margin: var(--space-2) var(--space-4);
    padding: 0;
    background: none;
    border: none;
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-text-secondary);
    cursor: pointer;
  }

  .caption-toggle:hover {
    color: var(--color-primary);
  }

  .caption-toggle:focus-visible {
    outline: 2px solid var(--color-primary);
    outline-offset: 2px;
    border-radius: var(--radius-sm);
  }

  .caption-chevron {
    transition: transform 0.15s ease;
  }

  .caption-chevron.open {
    transform: rotate(180deg);
  }

  @media (prefers-reduced-motion: reduce) {
    .caption-chevron {
      transition: none;
    }
  }

  .stream-content :global(a) {
    color: var(--color-primary);
    text-decoration: none;
  }

  .stream-content :global(a:hover) {
    text-decoration: underline;
  }

  .stream-actions {
    display: flex;
    gap: var(--space-4);
    padding: var(--space-2) var(--space-4) var(--space-3);
    border-block-start: 1px solid var(--color-border);
  }

  .stream-action-link {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    text-decoration: none;
  }

  .stream-action-link:hover {
    color: var(--color-primary);
    text-decoration: none;
  }

  .stream-action-link:focus-visible {
    color: var(--color-primary);
    outline: 2px solid var(--color-primary);
    outline-offset: 2px;
    border-radius: var(--radius-sm);
    text-decoration: none;
  }

  .stream-stat {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
  }

  .btn-outline {
    display: inline-flex;
    align-items: center;
    padding: var(--space-2) var(--space-3);
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    font-size: var(--text-sm);
    color: var(--color-text);
    cursor: pointer;
  }

  .btn-outline:hover {
    background: var(--color-surface);
  }

  /* ---- Skeleton loading cards ---- */
  .skel-video {
    width: 100%;
    aspect-ratio: 16 / 9;
    background: var(--color-border);
  }

  .skel-body {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: var(--space-4);
  }

  .skel-line {
    height: 12px;
    border-radius: var(--radius-sm);
    background: var(--color-border);
  }

  .skel-line-lg { width: 80%; }
  .skel-line-sm { width: 50%; }

  @media (prefers-reduced-motion: no-preference) {
    .skel-video,
    .skel-line {
      animation: skeleton-pulse 1.5s ease-in-out infinite;
    }
  }

  @keyframes skeleton-pulse {
    0%, 100% { opacity: 0.4; }
    50% { opacity: 0.7; }
  }
</style>
