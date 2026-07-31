<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client.js';
  import type { Post, MediaAttachment } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import PostActions from '$lib/components/post/PostActions.svelte';
  import Modal from '$lib/components/ui/Modal.svelte';
  import ThreadedReplies from '$lib/components/post/ThreadedReplies.svelte';
  import { getPostContext } from '$lib/api/statuses.js';
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

  // Mute is a single GLOBAL state shared by every clip, not per-video: unmute
  // one and every clip (including the next one you scroll to) plays with sound;
  // mute one and they all fall silent. Starts muted (browsers block sound-on
  // autoplay until a gesture) and is remembered across visits.
  const MUTED_KEY = 'hs-streams-muted';
  let muted = $state(true);

  function setMuted(next: boolean) {
    if (muted === next) return;
    muted = next;
    try {
      localStorage.setItem(MUTED_KEY, muted ? '1' : '0');
    } catch {
      /* storage unavailable — the choice just won't persist */
    }
  }

  function toggleMuted() {
    setMuted(!muted);
  }

  // The native <video controls> mute button is per-element; mirror any change
  // the viewer makes there back into the shared state so it propagates to
  // every other clip.
  function syncMutedFromVideo(e: Event) {
    setMuted((e.currentTarget as HTMLVideoElement).muted);
  }

  // Track which posts we've already reported a view for so we don't
  // double-count the initial `play` event.
  const viewsReported = new Set<string>();

  // Comments sheet — a full-bleed vertical feed has no room for an inline
  // thread, so the comment button opens a sheet (like the reels pattern) that
  // shows existing replies and lets the viewer add one, instead of only
  // launching a reply composer with no way to read the conversation.
  let commentsOpen = $state(false);
  let commentsPost = $state<Post | null>(null);
  let commentsDescendants = $state<Post[]>([]);
  let commentsLoading = $state(false);
  let commentsError = $state('');

  async function openComments(post: Post) {
    commentsPost = post;
    commentsOpen = true;
    commentsError = '';
    commentsDescendants = [];
    commentsLoading = true;
    try {
      const context = await getPostContext(post.id);
      commentsDescendants = context.descendants ?? [];
    } catch {
      commentsError = 'Failed to load comments.';
    } finally {
      commentsLoading = false;
    }
  }

  function closeComments() {
    commentsOpen = false;
    commentsPost = null;
    commentsDescendants = [];
  }

  function addComment() {
    if (!commentsPost) return;
    // Reuse the existing global composer for the actual reply; the new-post
    // listener below folds the result back into the open thread.
    window.dispatchEvent(
      new CustomEvent('open-composer', { detail: { replyTo: commentsPost } }),
    );
  }

  // Fold optimistic replies into the open thread so a just-sent comment shows
  // up immediately, matching how the post-detail thread reconciles them.
  function handleNewComment(e: Event) {
    const newPost = (e as CustomEvent<Post>).detail;
    if (!newPost || !commentsPost) return;
    const belongsHere =
      newPost.parent_id === commentsPost.id ||
      newPost.root_id === commentsPost.id ||
      commentsDescendants.some((d) => d.id === newPost.parent_id);
    if (belongsHere && !commentsDescendants.some((d) => d.id === newPost.id)) {
      commentsDescendants = [...commentsDescendants, newPost];
    }
  }

  // The composer posts an optimistic reply (temp id) then fires `post-replace`
  // with the real server post. Without handling it, a just-added comment stays
  // stuck as the pending optimistic object (temp `pending-*` id), so
  // reacting/replying to it targets a non-existent status until the sheet is
  // reopened. Swap it in place.
  function handleCommentReplace(e: Event) {
    const { oldId, post } = (e as CustomEvent<{ oldId: string; post: Post }>).detail ?? {};
    if (!oldId || !post) return;
    commentsDescendants = commentsDescendants.map((d) => (d.id === oldId ? post : d));
  }

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

  // Timeline ordering + free-text/hashtag filter. `trending` is the default
  // (matches the server) so it's omitted from the query on the happy path.
  let sort = $state<'trending' | 'newest' | 'oldest'>('trending');
  let search = $state('');
  let searchTimer: ReturnType<typeof setTimeout> | undefined;

  // Tap the clip body (not the native controls strip) to play/pause.
  function toggleStreamPlay(e: MouseEvent) {
    const wrapper = (e.currentTarget as HTMLElement).closest('.stream-video-wrapper');
    const video = wrapper?.querySelector('video');
    if (!video) return;
    if (video.paused) video.play().catch(() => {});
    else video.pause();
  }

  // The sound + autoplay controls scroll out of reach on a long feed. Reveal a
  // floating copy whenever the scroll DIRECTION changes, then hide it again
  // once the user keeps going the same way for about one clip — so they're
  // always a flick away without scrolling back to the top.
  let controlsRevealed = $state(false);
  let lastScrollTop = 0;
  let lastDir = 0; // -1 up, 1 down
  let revealAnchor = 0;
  const REVEAL_MIN = 120; // don't bother while the header row is still on screen
  const HIDE_AFTER = 320; // px of continued same-direction scroll (~one clip)

  // The page (window) scrolls — the feed has no internal overflow — so the
  // header scrolls away. Watch window scroll to reveal the floating controls.
  function onWindowScroll() {
    const top = window.scrollY;
    const delta = top - lastScrollTop;
    lastScrollTop = top;
    if (Math.abs(delta) < 2) return;

    const dir = delta > 0 ? 1 : -1;

    if (top <= REVEAL_MIN) {
      // Near the top the real header is visible; no floating copy needed.
      controlsRevealed = false;
    } else if (dir !== lastDir) {
      // Direction just reversed — flash the controls in.
      controlsRevealed = true;
      revealAnchor = top;
    } else if (controlsRevealed && Math.abs(top - revealAnchor) > HIDE_AFTER) {
      // Kept scrolling the same way past ~one clip — hide again.
      controlsRevealed = false;
    }

    lastDir = dir;
  }

  const SORTS: { value: 'trending' | 'newest' | 'oldest'; label: string }[] = [
    { value: 'trending', label: 'Trending' },
    { value: 'newest', label: 'Newest' },
    { value: 'oldest', label: 'Oldest' },
  ];

  async function loadStreams() {
    loading = true;
    error = '';
    try {
      const params: Record<string, string> = {};
      if (sort !== 'trending') params.sort = sort;
      const q = search.trim();
      if (q) params.q = q;
      const result = await api.get<any>('/api/v1/timelines/streams', params);
      const data = Array.isArray(result) ? result : (result as any)?.data || [];
      posts = data;
    } catch {
      error = 'Failed to load streams.';
    } finally {
      loading = false;
    }
  }

  function changeSort(next: 'trending' | 'newest' | 'oldest') {
    if (sort === next) return;
    sort = next;
    loadStreams();
  }

  // Debounce typing so we don't fire a request per keystroke.
  function onSearchInput() {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => loadStreams(), 300);
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

  function reportImpression(postId: string, video: HTMLVideoElement) {
    if (viewsReported.has(postId)) return;

    // `play` can fire before metadata loads (preload="none"), when duration is
    // still 0/NaN. The backend requires total_duration > 0, so reporting then
    // 422s and the impression is lost. Wait for a real duration — the
    // `loadedmetadata` retry below carries it, and dedup guards a single report.
    const duration = video.duration;
    if (!Number.isFinite(duration) || duration <= 0) return;

    viewsReported.add(postId);
    reportView(postId, 0, duration, false, false);
  }

  function handlePlay(postId: string, event: Event) {
    reportImpression(postId, event.currentTarget as HTMLVideoElement);
  }

  // When `play` fired before metadata was ready, its impression was skipped;
  // once the duration lands, report it — but only if the clip is still playing,
  // so we never log a view for a video the user scrolled past unplayed.
  function handleLoadedMetadata(postId: string, event: Event) {
    const video = event.currentTarget as HTMLVideoElement;
    if (!video.paused) reportImpression(postId, video);
  }

  function handleEnded(postId: string, event: Event) {
    const video = event.currentTarget as HTMLVideoElement;
    const duration = video.duration;
    if (!Number.isFinite(duration) || duration <= 0) return;

    const replayed = viewsReported.has(`${postId}:ended`);

    viewsReported.add(`${postId}:ended`);
    reportView(postId, duration, duration, true, replayed);
  }

  onMount(() => {
    try {
      autoplay = localStorage.getItem(AUTOPLAY_KEY) === '1';
      // Default to muted unless the viewer previously chose sound-on.
      muted = localStorage.getItem(MUTED_KEY) !== '0';
    } catch {
      /* ignore */
    }
    loadStreams();
    window.addEventListener('new-post', handleNewComment);
    window.addEventListener('post-replace', handleCommentReplace);
    return () => {
      window.removeEventListener('new-post', handleNewComment);
      window.removeEventListener('post-replace', handleCommentReplace);
    };
  });

  // Loads metadata as a card nears the viewport, pauses playback when it
  // scrolls away, and — when autoplay is enabled — plays it (muted) once it's
  // mostly in view. The autoplay flag is passed reactively via the action
  // parameter, so toggling it takes effect on already-mounted videos.
  function lazyVideo(node: HTMLVideoElement, params: { autoplay: boolean; muted: boolean }) {
    let auto = params.autoplay;
    let isMuted = params.muted;
    // Track the clip's latest visibility so toggling autoplay ON can start a
    // clip that's already in view (the observer won't re-fire on its own).
    let lastRatio = 0;
    node.muted = isMuted;
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const ratio = entry.intersectionRatio;
          lastRatio = ratio;
          if (entry.isIntersecting && ratio >= 0.25 && node.preload === 'none') {
            node.preload = 'metadata';
          }
          if (!entry.isIntersecting || ratio < 0.25) {
            // Off-screen — pause so audio never plays out of view.
            if (!node.paused) node.pause();
          } else if (auto && ratio >= 0.6) {
            // Mostly in view and autoplay is on — honor the shared mute state
            // so the clip you scroll to plays with sound once you've unmuted.
            node.muted = isMuted;
            node.play().catch(() => {});
          }
        }
      },
      { threshold: [0, 0.25, 0.6] },
    );
    io.observe(node);
    return {
      update(next: { autoplay: boolean; muted: boolean }) {
        const wasAuto = auto;
        auto = next.autoplay;
        // Re-apply the shared mute state to this already-mounted clip so a
        // global toggle reaches every video, not just the one interacted with.
        if (isMuted !== next.muted) {
          isMuted = next.muted;
          node.muted = isMuted;
        }
        if (!auto && !node.paused) {
          node.pause();
        } else if (auto && !wasAuto && lastRatio >= 0.6 && node.paused) {
          // Autoplay just turned on and this clip is already mostly in view —
          // start it now (the IntersectionObserver only fires on a change).
          node.muted = isMuted;
          node.play().catch(() => {});
        }
      },
      destroy: () => io.disconnect(),
    };
  }
</script>

<svelte:head>
  <title>Streams - {$instanceName}</title>
</svelte:head>

<svelte:window onscroll={onWindowScroll} />

<div class="streams-page">
  <!-- Floating copy of the sound + autoplay controls, revealed on scroll
       direction change (see onFeedScroll) so they're reachable mid-feed. -->
  <div class="streams-floating-controls" class:revealed={controlsRevealed} aria-hidden={!controlsRevealed}>
    <button
      type="button"
      class="float-btn"
      class:on={!muted}
      aria-label={muted ? 'Unmute all streams' : 'Mute all streams'}
      tabindex={controlsRevealed ? 0 : -1}
      onclick={toggleMuted}
    >
      {#if muted}
        <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3.63 3.63a.996.996 0 0 0 0 1.41L7.29 8.7 7 9H4a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h3l3.29 3.29c.63.63 1.71.18 1.71-.71v-4.17l4.18 4.18c-.49.37-1.02.68-1.6.91v2.06a8.9 8.9 0 0 0 3.02-1.32l1.65 1.65a.996.996 0 1 0 1.41-1.41L5.05 3.63a.996.996 0 0 0-1.42 0zM19 12c0 .82-.15 1.61-.41 2.34l1.53 1.53A8.9 8.9 0 0 0 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71z" /></svg>
      {:else}
        <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 10v4a1 1 0 0 0 1 1h3l3.29 3.29c.63.63 1.71.18 1.71-.71V6.41c0-.89-1.08-1.34-1.71-.71L7 9H4a1 1 0 0 0-1 1zm13.5 2A4.5 4.5 0 0 0 14 7.97v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z" /></svg>
      {/if}
    </button>
    <button
      type="button"
      class="float-btn"
      class:on={autoplay}
      aria-label={autoplay ? 'Autoplay on' : 'Autoplay off'}
      tabindex={controlsRevealed ? 0 : -1}
      onclick={toggleAutoplay}
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5v14l11-7z" /></svg>
    </button>
  </div>

  <div class="page-header">
    <h1 class="page-title">Streams</h1>
    <div class="header-controls">
      <button
        type="button"
        class="autoplay-toggle"
        class:on={!muted}
        role="switch"
        aria-checked={!muted}
        aria-label={muted ? 'Unmute all streams' : 'Mute all streams'}
        onclick={toggleMuted}
      >
        {#if muted}
          <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3.63 3.63a.996.996 0 0 0 0 1.41L7.29 8.7 7 9H4a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h3l3.29 3.29c.63.63 1.71.18 1.71-.71v-4.17l4.18 4.18c-.49.37-1.02.68-1.6.91v2.06a8.9 8.9 0 0 0 3.02-1.32l1.65 1.65a.996.996 0 1 0 1.41-1.41L5.05 3.63a.996.996 0 0 0-1.42 0zM12 4.9l-1.13 1.13L12 7.16V4.9zM19 12c0 .82-.15 1.61-.41 2.34l1.53 1.53A8.9 8.9 0 0 0 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71z" /></svg>
        {:else}
          <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 10v4a1 1 0 0 0 1 1h3l3.29 3.29c.63.63 1.71.18 1.71-.71V6.41c0-.89-1.08-1.34-1.71-.71L7 9H4a1 1 0 0 0-1 1zm13.5 2A4.5 4.5 0 0 0 14 7.97v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z" /></svg>
        {/if}
        {muted ? 'Sound off' : 'Sound on'}
      </button>
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
  </div>

  <div class="streams-controls">
    <div class="streams-search">
      <svg class="streams-search-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" />
      </svg>
      <input
        type="search"
        class="streams-search-input"
        placeholder="Search clips or #tags…"
        aria-label="Search streams"
        bind:value={search}
        oninput={onSearchInput}
      />
    </div>
    <div class="streams-sort" role="group" aria-label="Sort clips by">
      {#each SORTS as s (s.value)}
        <button
          type="button"
          class="sort-chip"
          class:on={sort === s.value}
          aria-pressed={sort === s.value}
          onclick={() => changeSort(s.value)}
        >
          {s.label}
        </button>
      {/each}
    </div>
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
                use:lazyVideo={{ autoplay, muted }}
                onplay={(e) => handlePlay(post.id, e)}
                onloadedmetadata={(e) => handleLoadedMetadata(post.id, e)}
                onended={(e) => handleEnded(post.id, e)}
                onvolumechange={syncMutedFromVideo}
              >
                <track kind="captions" />
              </video>
              <!-- Tap the clip (above the native controls strip) to play/pause,
                   without disturbing the scrubber or the display style. -->
              <button
                type="button"
                class="stream-tap"
                aria-label="Play or pause"
                onclick={toggleStreamPlay}
              ></button>
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
            <!-- Full, interactive action bar (react + who-reacted detail +
                 reply/comment + boost/bookmark/share) instead of the old
                 read-only counts, so viewers can engage without leaving the
                 feed. -->
            <PostActions {post} oncomment={() => openComments(post)} />
          </div>
        </div>
      {/each}
    </div>
  {/if}
</div>

<Modal open={commentsOpen} title="Comments" onclose={closeComments}>
  <div class="comments-sheet">
    <button type="button" class="comments-add" onclick={addComment}>
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M12 5v14M5 12h14" />
      </svg>
      Add a comment
    </button>

    {#if commentsLoading}
      <p class="comments-status">Loading comments…</p>
    {:else if commentsError}
      <p class="comments-status">{commentsError}</p>
    {:else if !commentsPost || commentsDescendants.length === 0}
      <p class="comments-status">No comments yet. Be the first to comment.</p>
    {:else}
      <ThreadedReplies descendants={commentsDescendants} rootPostId={commentsPost.id} />
    {/if}
  </div>
</Modal>

<style>
  .streams-page {
    max-width: var(--feed-max-width);
    margin: 0 auto;
  }

  /* Floating sound + autoplay controls, revealed on scroll-direction change.
     Fixed (the window scrolls), just under the app header. */
  .streams-floating-controls {
    position: fixed;
    inset-block-start: calc(var(--header-height, 60px) + var(--space-2));
    inset-inline-end: var(--space-4);
    z-index: 50;
    display: flex;
    gap: var(--space-2);
    opacity: 0;
    transform: translateY(-10px);
    pointer-events: none;
    transition: opacity 180ms ease, transform 180ms ease;
  }

  .streams-floating-controls.revealed {
    opacity: 1;
    transform: none;
    pointer-events: auto;
  }

  .float-btn {
    display: grid;
    place-items: center;
    width: 40px;
    height: 40px;
    padding: 0;
    border: none;
    border-radius: 50%;
    background: color-mix(in oklab, var(--color-surface-base, #fff) 80%, transparent);
    color: var(--color-text-secondary);
    cursor: pointer;
    backdrop-filter: saturate(1.4) blur(10px);
    -webkit-backdrop-filter: saturate(1.4) blur(10px);
    box-shadow: 0 4px 14px rgba(0, 0, 0, 0.18);
    transition: color 150ms ease, background 150ms ease;
  }

  .float-btn:hover {
    color: var(--color-text);
  }

  .float-btn.on {
    color: var(--color-primary);
  }

  /* Center-tap play/pause surface — covers the clip but clears the bottom
     native-controls strip so the scrubber/volume stay usable. */
  .stream-tap {
    position: absolute;
    inset: 0 0 44px 0;
    padding: 0;
    border: none;
    background: transparent;
    cursor: pointer;
  }

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    margin-block-end: var(--space-4);
  }

  .header-controls {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
  }

  .streams-controls {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    flex-wrap: wrap;
    margin-block-end: var(--space-4);
  }

  .streams-search {
    position: relative;
    flex: 1 1 220px;
    min-width: 0;
    display: flex;
    align-items: center;
  }

  .streams-search-icon {
    position: absolute;
    inset-inline-start: var(--space-3);
    color: var(--color-text-tertiary);
    pointer-events: none;
  }

  .streams-search-input {
    width: 100%;
    padding: var(--space-2) var(--space-3);
    padding-inline-start: calc(var(--space-3) + 16px + var(--space-2));
    border: 1px solid var(--color-border);
    border-radius: var(--radius-full);
    background: var(--color-surface);
    color: var(--color-text);
    font-size: var(--text-sm);
    text-align: start;
  }

  .streams-search-input:focus-visible {
    outline: none;
    border-color: var(--color-primary);
  }

  .streams-sort {
    display: inline-flex;
    gap: var(--space-1);
    flex-shrink: 0;
  }

  .sort-chip {
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

  .sort-chip:hover {
    color: var(--color-text);
    border-color: var(--color-text-tertiary);
  }

  .sort-chip.on {
    background: var(--color-primary-soft, rgba(var(--color-primary-rgb), 0.12));
    color: var(--color-primary);
    border-color: transparent;
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

  .comments-sheet {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .comments-add {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    align-self: stretch;
    justify-content: center;
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-full);
    background: transparent;
    color: var(--color-primary);
    font-size: var(--text-sm);
    font-weight: 600;
    cursor: pointer;
    transition: background 150ms ease, border-color 150ms ease;
  }

  .comments-add:hover {
    background: var(--color-primary-soft, rgba(var(--color-primary-rgb), 0.12));
    border-color: transparent;
  }

  .comments-status {
    padding: var(--space-4) 0;
    text-align: center;
    color: var(--color-text-secondary);
    font-size: var(--text-sm);
  }

  .stream-card {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl);
    /* No `overflow: hidden` here — it would clip the reaction picker that
       pops out of the action bar past the card edge. The rounded top corners
       are instead clipped on the video wrapper below. */
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
    /* Round only the top corners to match the card, and clip the video to
       them (the card no longer clips for us). */
    overflow: hidden;
    border-start-start-radius: var(--radius-xl);
    border-start-end-radius: var(--radius-xl);
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
