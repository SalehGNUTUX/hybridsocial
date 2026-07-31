<script lang="ts">
  import type { Post, MediaAttachment } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import PostActions from '$lib/components/post/PostActions.svelte';

  let {
    post,
    video,
    muted,
    autoplay,
    onmutetoggle,
    onautoplaytoggle,
    onsearch,
    onsort,
    oncomment,
    onview,
  }: {
    post: Post;
    video: MediaAttachment;
    /** Global, shared across every reel (see the page). */
    muted: boolean;
    autoplay: boolean;
    onmutetoggle: () => void;
    /** Feed-level controls, overlaid on the clip (top-right). */
    onautoplaytoggle: () => void;
    onsearch: () => void;
    onsort: () => void;
    oncomment?: () => void;
    /** Report a view. Called once at start (impression) and once at end. */
    onview: (
      watchDuration: number,
      totalDuration: number,
      completed: boolean,
      replayed: boolean,
    ) => void;
  } = $props();

  // --- Player element + playback state -------------------------------------
  let videoEl: HTMLVideoElement | undefined = $state();
  let playing = $state(false);
  let duration = $state(0);
  let currentTime = $state(0);
  // Caption is hidden by default — a reel is a video-first surface. The toggle
  // lives in the action row so the content never covers the clip uninvited.
  let captionOpen = $state(false);
  // A brief center play/pause glyph that flashes on tap, then fades.
  let tapGlyph = $state<'play' | 'pause' | null>(null);
  let tapGlyphTimer: ReturnType<typeof setTimeout> | undefined;

  // Keep the element's muted flag in sync with the shared state so a global
  // toggle reaches this clip even while it's mid-play.
  $effect(() => {
    if (videoEl) videoEl.muted = muted;
  });

  // Latest visibility of this clip, as seen by the IntersectionObserver. The
  // observer only re-fires on an intersection *change*, so toggling autoplay
  // while a clip is already parked in view wouldn't otherwise reach it.
  let lastRatio = $state(0);

  // React to the autoplay toggle on the already-mounted clip: turning it off
  // pauses a playing reel; turning it on starts the one currently in view.
  $effect(() => {
    if (!videoEl) return;
    if (!autoplay) {
      if (!videoEl.paused) videoEl.pause();
    } else if (lastRatio >= 0.6 && videoEl.paused) {
      videoEl.muted = muted;
      videoEl.play().catch(() => {});
    }
  });

  function firstFrameSrc(url: string): string {
    return url.includes('#') ? url : `${url}#t=0.1`;
  }

  function videoPoster(m: MediaAttachment): string | undefined {
    if (!m.preview_url || m.preview_url === m.url) return undefined;
    return m.preview_url;
  }

  function fmt(t: number): string {
    if (!Number.isFinite(t) || t < 0) t = 0;
    const m = Math.floor(t / 60);
    const s = Math.floor(t % 60);
    return `${m}:${String(s).padStart(2, '0')}`;
  }

  // --- View reporting ------------------------------------------------------
  let impressionSent = false;
  let endReported = false;

  function onLoadedMetadata() {
    if (videoEl) duration = videoEl.duration || 0;
  }

  function onTimeUpdate() {
    if (!videoEl || scrubbing) return;
    currentTime = videoEl.currentTime;
    // Fire the impression only once we have a real duration (the backend
    // rejects total_duration <= 0), matching the Streams guard.
    if (!impressionSent && Number.isFinite(videoEl.duration) && videoEl.duration > 0) {
      impressionSent = true;
      onview(0, videoEl.duration, false, false);
    }
  }

  function onPlayEvt() {
    playing = true;
  }
  function onPauseEvt() {
    playing = false;
  }
  function onEndedEvt() {
    if (!videoEl) return;
    const d = videoEl.duration;
    if (!Number.isFinite(d) || d <= 0) return;
    const replayed = endReported;
    endReported = true;
    onview(d, d, true, replayed);
  }

  // --- Center tap: play / pause -------------------------------------------
  function togglePlay() {
    if (!videoEl) return;
    if (videoEl.paused) {
      videoEl.play().catch(() => {});
      flashGlyph('play');
    } else {
      videoEl.pause();
      flashGlyph('pause');
    }
  }

  function flashGlyph(g: 'play' | 'pause') {
    tapGlyph = g;
    clearTimeout(tapGlyphTimer);
    tapGlyphTimer = setTimeout(() => {
      tapGlyph = null;
    }, 450);
  }

  // --- Autoplay / pause on scroll, lazy metadata --------------------------
  function reelObserver(node: HTMLVideoElement) {
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const ratio = entry.intersectionRatio;
          lastRatio = ratio;
          if (entry.isIntersecting && ratio >= 0.25 && node.preload === 'none') {
            node.preload = 'metadata';
          }
          if (!entry.isIntersecting || ratio < 0.25) {
            if (!node.paused) node.pause();
          } else if (autoplay && ratio >= 0.6) {
            node.muted = muted;
            node.play().catch(() => {});
          }
        }
      },
      { threshold: [0, 0.25, 0.6] },
    );
    io.observe(node);
    return { destroy: () => io.disconnect() };
  }

  // --- Circular scrubber ring ---------------------------------------------
  // The ring wraps the mute button (top-left). It fills with playback
  // progress; grabbing the handle dot seeks. Center of the SVG is (RING/2).
  const RING = 56;
  const R = 24;
  const C = 2 * Math.PI * R;
  const CENTER = RING / 2;

  let progress = $derived(duration > 0 ? Math.min(1, currentTime / duration) : 0);
  // Handle angle: start at 12 o'clock, clockwise.
  let handleAngle = $derived(progress * 2 * Math.PI - Math.PI / 2);
  let handleX = $derived(CENTER + R * Math.cos(handleAngle));
  let handleY = $derived(CENTER + R * Math.sin(handleAngle));

  let scrubbing = $state(false);
  let showTime = $state(false);
  let showTimeTimer: ReturnType<typeof setTimeout> | undefined;
  let ringEl: SVGSVGElement | undefined = $state();

  function progressFromPointer(clientX: number, clientY: number): number {
    if (!ringEl) return 0;
    const rect = ringEl.getBoundingClientRect();
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;
    // Angle measured from 12 o'clock, clockwise, normalized to [0, 1).
    let a = Math.atan2(clientY - cy, clientX - cx) + Math.PI / 2;
    if (a < 0) a += 2 * Math.PI;
    return a / (2 * Math.PI);
  }

  function seekTo(p: number) {
    if (!videoEl || duration <= 0) return;
    const t = Math.max(0, Math.min(duration, p * duration));
    videoEl.currentTime = t;
    currentTime = t;
  }

  function onRingPointerDown(e: PointerEvent) {
    e.preventDefault();
    e.stopPropagation();
    scrubbing = true;
    showTime = true;
    clearTimeout(showTimeTimer);
    (e.currentTarget as Element).setPointerCapture?.(e.pointerId);
    seekTo(progressFromPointer(e.clientX, e.clientY));
  }

  function onRingPointerMove(e: PointerEvent) {
    if (!scrubbing) return;
    seekTo(progressFromPointer(e.clientX, e.clientY));
  }

  function onRingPointerUp(e: PointerEvent) {
    if (!scrubbing) return;
    scrubbing = false;
    (e.currentTarget as Element).releasePointerCapture?.(e.pointerId);
    // Keep the time label visible for a beat after release, then fade.
    clearTimeout(showTimeTimer);
    showTimeTimer = setTimeout(() => {
      showTime = false;
    }, 3000);
  }
</script>

<section class="reel">
 <!-- The frame is sized to the actual clip (9:16); every overlay anchors to
      it, not to the full-width section — so the ring sits on the clip's
      corner and the action bar matches the clip width on every screen. -->
 <div class="reel-frame">
  <!-- Tapping the video area toggles play/pause. Overlays above stop their
       own taps from reaching it. -->
  <button
    type="button"
    class="reel-stage"
    aria-label={playing ? 'Pause' : 'Play'}
    onclick={togglePlay}
  >
    <video
      bind:this={videoEl}
      src={firstFrameSrc(video.url)}
      poster={videoPoster(video)}
      playsinline
      preload="none"
      class="reel-video"
      aria-label={video.description || 'Reel'}
      use:reelObserver
      onloadedmetadata={onLoadedMetadata}
      ontimeupdate={onTimeUpdate}
      onplay={onPlayEvt}
      onpause={onPauseEvt}
      onended={onEndedEvt}
    >
      <track kind="captions" />
    </video>
  </button>

  {#if tapGlyph}
    <div class="tap-glyph" aria-hidden="true">
      {#if tapGlyph === 'play'}
        <svg width="34" height="34" viewBox="0 0 24 24" fill="#fff"><path d="M8 5v14l11-7z" /></svg>
      {:else}
        <svg width="34" height="34" viewBox="0 0 24 24" fill="#fff"><path d="M6 5h4v14H6zM14 5h4v14h-4z" /></svg>
      {/if}
    </div>
  {/if}

  <!-- Feed controls overlaid on the clip, top-right: autoplay, search, sort. -->
  <div class="reel-topbar">
    <button
      type="button"
      class="reel-icon-btn"
      class:on={autoplay}
      aria-pressed={autoplay}
      aria-label={autoplay ? 'Autoplay on' : 'Autoplay off'}
      onclick={(e) => { e.stopPropagation(); onautoplaytoggle(); }}
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5v14l11-7z" /></svg>
    </button>
    <button
      type="button"
      class="reel-icon-btn"
      aria-label="Search reels"
      onclick={(e) => { e.stopPropagation(); onsearch(); }}
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="7" /><line x1="21" y1="21" x2="16.65" y2="16.65" /></svg>
    </button>
    <button
      type="button"
      class="reel-icon-btn"
      aria-label="Sort reels"
      onclick={(e) => { e.stopPropagation(); onsort(); }}
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M6 12h12M10 18h4" /></svg>
    </button>
  </div>

  <!-- Mute button + circular scrubber, top-left. -->
  <div class="reel-ring-wrap">
    <svg
      bind:this={ringEl}
      class="reel-ring"
      class:scrubbing
      width={RING}
      height={RING}
      viewBox="0 0 {RING} {RING}"
      onpointerdown={onRingPointerDown}
      onpointermove={onRingPointerMove}
      onpointerup={onRingPointerUp}
      onpointercancel={onRingPointerUp}
      role="slider"
      tabindex="-1"
      aria-label="Seek"
      aria-valuemin={0}
      aria-valuemax={Math.round(duration)}
      aria-valuenow={Math.round(currentTime)}
    >
      <circle class="ring-track" cx={CENTER} cy={CENTER} r={R} fill="none" />
      <circle
        class="ring-progress"
        cx={CENTER}
        cy={CENTER}
        r={R}
        fill="none"
        stroke-dasharray={C}
        stroke-dashoffset={C * (1 - progress)}
        transform="rotate(-90 {CENTER} {CENTER})"
      />
      <circle class="ring-handle" cx={handleX} cy={handleY} r={scrubbing ? 7 : 4} />
    </svg>
    <button
      type="button"
      class="reel-mute"
      aria-label={muted ? 'Unmute' : 'Mute'}
      onclick={(e) => {
        e.stopPropagation();
        onmutetoggle();
      }}
    >
      {#if muted}
        <svg width="18" height="18" viewBox="0 0 24 24" fill="#fff" aria-hidden="true"><path d="M3.63 3.63a.996.996 0 0 0 0 1.41L7.29 8.7 7 9H4a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h3l3.29 3.29c.63.63 1.71.18 1.71-.71v-4.17l4.18 4.18c-.49.37-1.02.68-1.6.91v2.06a8.9 8.9 0 0 0 3.02-1.32l1.65 1.65a.996.996 0 1 0 1.41-1.41L5.05 3.63a.996.996 0 0 0-1.42 0zM19 12c0 .82-.15 1.61-.41 2.34l1.53 1.53A8.9 8.9 0 0 0 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71z" /></svg>
      {:else}
        <svg width="18" height="18" viewBox="0 0 24 24" fill="#fff" aria-hidden="true"><path d="M3 10v4a1 1 0 0 0 1 1h3l3.29 3.29c.63.63 1.71.18 1.71-.71V6.41c0-.89-1.08-1.34-1.71-.71L7 9H4a1 1 0 0 0-1 1zm13.5 2A4.5 4.5 0 0 0 14 7.97v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z" /></svg>
      {/if}
    </button>
    {#if showTime}
      <span class="reel-time" aria-hidden="true">{fmt(currentTime)} / {fmt(duration)}</span>
    {/if}
  </div>

  <!-- Author, optional caption, and the action bar over a legibility scrim. -->
  <div class="reel-overlay">
    <a href="/@{post.account.handle}" class="reel-author">
      <Avatar src={post.account.avatar_url} name={post.account.display_name || post.account.handle} size="sm" />
      <span class="reel-author-name">{post.account.display_name || post.account.handle}</span>
    </a>

    {#if captionOpen && post.content}
      <p class="reel-caption" dir="auto">{post.content}</p>
    {/if}

    <div class="reel-actions">
      <PostActions {post} {oncomment} />
      {#if post.content}
        <button
          type="button"
          class="caption-toggle"
          class:on={captionOpen}
          aria-pressed={captionOpen}
          aria-label={captionOpen ? 'Hide caption' : 'Show caption'}
          onclick={() => (captionOpen = !captionOpen)}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M4 7h16M4 12h16M4 17h10" />
          </svg>
        </button>
      {/if}
    </div>
  </div>
 </div>
</section>

<style>
  .reel {
    position: relative;
    flex: 0 0 100%;
    height: 100%;
    scroll-snap-align: center;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  /* The actual clip box (9:16). Every overlay is positioned relative to THIS,
     not the full-width .reel section, so controls anchor to the clip on every
     screen. overflow:hidden clips overlays to the rounded corners. */
  .reel-frame {
    position: relative;
    height: 100%;
    max-height: 100%;
    aspect-ratio: 9 / 16;
    max-width: 100%;
    border-radius: var(--radius-lg);
    overflow: hidden;
    background: #000;
  }

  /* The tap surface fills the frame; it carries no visual style of its own. */
  .reel-stage {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    border: none;
    background: transparent;
    cursor: pointer;
  }

  .reel-video {
    width: 100%;
    height: 100%;
    object-fit: cover;
    background: #000;
  }

  /* Feed controls overlaid on the clip's top-right (autoplay / search / sort). */
  .reel-topbar {
    position: absolute;
    inset-block-start: var(--space-3);
    inset-inline-end: var(--space-3);
    display: flex;
    gap: var(--space-2);
    z-index: 2;
  }

  .reel-icon-btn {
    display: grid;
    place-items: center;
    width: 36px;
    height: 36px;
    padding: 0;
    border: none;
    border-radius: 50%;
    background: rgba(0, 0, 0, 0.45);
    color: #fff;
    cursor: pointer;
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    transition: background 150ms ease, color 150ms ease;
  }

  .reel-icon-btn:hover {
    background: rgba(0, 0, 0, 0.65);
  }

  .reel-icon-btn.on {
    background: var(--color-primary, #6c3edd);
  }

  .tap-glyph {
    position: absolute;
    inset-block-start: 50%;
    inset-inline-start: 50%;
    transform: translate(-50%, -50%);
    display: grid;
    place-items: center;
    width: 64px;
    height: 64px;
    border-radius: 50%;
    background: rgba(0, 0, 0, 0.45);
    pointer-events: none;
    animation: glyph-fade 450ms ease forwards;
  }

  @keyframes glyph-fade {
    0% { opacity: 0; transform: translate(-50%, -50%) scale(0.7); }
    30% { opacity: 1; transform: translate(-50%, -50%) scale(1); }
    100% { opacity: 0; transform: translate(-50%, -50%) scale(1.1); }
  }

  /* --- Top-left mute + scrubber ring --- */
  .reel-ring-wrap {
    position: absolute;
    inset-block-start: var(--space-3);
    inset-inline-start: var(--space-3);
    width: 56px;
    height: 56px;
  }

  .reel-ring {
    position: absolute;
    inset: 0;
    /* Only the handle is a drag target by default; let taps on the empty ring
       area fall through to the mute button, but the handle captures pointers. */
    touch-action: none;
    overflow: visible;
  }

  .ring-track {
    stroke: rgba(255, 255, 255, 0.28);
    stroke-width: 3;
  }

  .ring-progress {
    stroke: var(--color-primary, #6c3edd);
    stroke-width: 3;
    stroke-linecap: round;
    transition: stroke-dashoffset 120ms linear;
  }

  .reel-ring.scrubbing .ring-progress {
    transition: none;
  }

  .ring-handle {
    fill: #fff;
    filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.5));
    cursor: grab;
    transition: r 120ms ease;
  }

  .reel-ring.scrubbing .ring-handle {
    cursor: grabbing;
  }

  .reel-mute {
    position: absolute;
    inset-block-start: 50%;
    inset-inline-start: 50%;
    transform: translate(-50%, -50%);
    width: 34px;
    height: 34px;
    display: grid;
    place-items: center;
    padding: 0;
    border: none;
    border-radius: 50%;
    background: rgba(0, 0, 0, 0.45);
    cursor: pointer;
  }

  .reel-time {
    position: absolute;
    inset-block-start: calc(100% + 4px);
    inset-inline-start: 50%;
    transform: translateX(-50%);
    white-space: nowrap;
    font-size: var(--text-xs);
    font-weight: 600;
    color: #fff;
    background: rgba(0, 0, 0, 0.55);
    padding: 2px 8px;
    border-radius: var(--radius-full);
    pointer-events: none;
  }

  /* --- Bottom overlay --- */
  .reel-overlay {
    position: absolute;
    inset-inline: 0;
    bottom: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-8) var(--space-3) var(--space-3);
    background: linear-gradient(to top, rgba(0, 0, 0, 0.6), transparent);
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
    max-height: 30vh;
    overflow-y: auto;
    white-space: pre-wrap;
    overscroll-behavior: contain;
  }

  .reel-actions {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    background: var(--color-surface-raised);
    border-radius: var(--radius-full);
    padding-inline: var(--space-1);
    /* Never wider than the clip — if the action row is long, scroll it inside
       the pill rather than spilling past the clip's right edge. */
    max-width: 100%;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .reel-actions::-webkit-scrollbar {
    display: none;
  }

  .caption-toggle {
    display: grid;
    place-items: center;
    width: 34px;
    height: 34px;
    padding: 0;
    border: none;
    background: transparent;
    color: var(--color-text-secondary);
    border-radius: 50%;
    cursor: pointer;
    transition: color 150ms ease, background 150ms ease;
  }

  .caption-toggle:hover {
    color: var(--color-text);
    background: var(--color-surface-container-high);
  }

  .caption-toggle.on {
    color: var(--color-primary);
  }
</style>
