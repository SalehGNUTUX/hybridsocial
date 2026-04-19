<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import type { MediaAttachment, Identity } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';

  // Multi-strand audio player. The waveform envelope is baked once
  // from the decoded audio; each draw frame renders N overlapping
  // 1px strands whose phase is offset in time so they shimmer while
  // the track plays. Idle state still shows the envelope but without
  // the phase drift.

  let {
    media,
    author = null
  }: {
    media: MediaAttachment;
    author?: Identity | null;
  } = $props();

  let audioEl: HTMLAudioElement | undefined = $state();
  let canvasEl: HTMLCanvasElement | undefined = $state();

  let playing = $state(false);
  let currentTime = $state(0);
  let duration = $state(0);
  let speed = $state(1);
  let peaks: number[] = $state([]);
  let peaksLoaded = $state(false);

  const SPEEDS = [1, 1.25, 1.5, 1.75, 2];
  const BIN_COUNT = 260;
  const STRAND_COUNT = 10;

  let rafId: number | null = null;
  let animPhase = 0;
  let lastFrameTs = 0;

  async function loadWaveform() {
    if (!media.url) return;
    try {
      const res = await fetch(media.url, { credentials: 'omit' });
      if (!res.ok) return;
      const buf = await res.arrayBuffer();

      const Ctx = (window.AudioContext ||
        (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext) as
        | typeof AudioContext
        | undefined;
      if (!Ctx) return;
      const ctx = new Ctx();
      const audio = await ctx.decodeAudioData(buf);

      const channelData = audio.getChannelData(0);
      const step = Math.floor(channelData.length / BIN_COUNT) || 1;
      const result: number[] = new Array(BIN_COUNT);
      for (let i = 0; i < BIN_COUNT; i++) {
        let sum = 0;
        const start = i * step;
        const end = Math.min(start + step, channelData.length);
        for (let j = start; j < end; j++) sum += Math.abs(channelData[j]);
        result[i] = sum / Math.max(1, end - start);
      }

      const max = Math.max(...result, 0.001);
      peaks = result.map((v) => Math.max(0.08, v / max));
      peaksLoaded = true;
      try { await ctx.close(); } catch { /* ignore */ }
      drawWaveform();
    } catch {
      peaks = Array.from({ length: BIN_COUNT }, (_, i) => 0.3 + 0.6 * Math.abs(Math.sin(i * 0.12)));
      peaksLoaded = true;
      drawWaveform();
    }
  }

  function drawWaveform() {
    if (!canvasEl || peaks.length === 0) return;
    const dpr = window.devicePixelRatio || 1;
    const rect = canvasEl.getBoundingClientRect();
    const w = rect.width;
    const h = rect.height;
    if (w === 0 || h === 0) return;
    canvasEl.width = w * dpr;
    canvasEl.height = h * dpr;
    const ctx = canvasEl.getContext('2d');
    if (!ctx) return;
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, w, h);

    const progress = duration > 0 ? currentTime / duration : 0;
    const splitX = w * progress;

    const stepX = w / peaks.length;
    const midY = h / 2;

    // N strands, each with its own phase shift + slight frequency
    // variation. When the track is playing, animPhase advances each
    // frame so the strands shimmer. When paused it holds still so
    // the user can see the envelope cleanly.
    for (let s = 0; s < STRAND_COUNT; s++) {
      const strandFrac = s / (STRAND_COUNT - 1 || 1);
      const strandScale = 0.45 + 0.55 * strandFrac;
      const strandFreq = 0.18 + 0.08 * strandFrac;
      const strandPhase = strandFrac * Math.PI * 2 + animPhase * (0.8 + strandFrac * 0.6);

      ctx.lineWidth = 1;
      ctx.beginPath();
      for (let i = 0; i < peaks.length; i++) {
        const x = i * stepX;
        const jitter = Math.sin(i * strandFreq + strandPhase) * 1.2;
        const amp = peaks[i] * (midY - 4) * strandScale;
        const y = midY + jitter - amp;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      for (let i = peaks.length - 1; i >= 0; i--) {
        const x = i * stepX;
        const jitter = Math.sin(i * strandFreq + strandPhase) * 1.2;
        const amp = peaks[i] * (midY - 4) * strandScale;
        const y = midY + jitter + amp;
        ctx.lineTo(x, y);
      }
      ctx.closePath();

      const grad = ctx.createLinearGradient(0, 0, w, 0);
      grad.addColorStop(0, `rgba(23, 67, 85, ${0.16 + strandFrac * 0.14})`);
      grad.addColorStop(1, `rgba(97, 226, 255, ${0.22 + strandFrac * 0.2})`);
      ctx.strokeStyle = grad;
      ctx.stroke();
    }

    // Played-region brighten overlay.
    if (splitX > 0) {
      ctx.fillStyle = 'rgba(97, 226, 255, 0.06)';
      ctx.fillRect(0, 0, splitX, h);
    }
  }

  // Per-frame animation loop. Only runs while playing; paused state
  // stays frozen so decoding isn't wasted + battery-aware.
  function tick(ts: number) {
    if (!playing) return;
    if (lastFrameTs === 0) lastFrameTs = ts;
    const dt = (ts - lastFrameTs) / 1000;
    lastFrameTs = ts;
    animPhase += dt * 2.2; // radians/sec
    drawWaveform();
    rafId = requestAnimationFrame(tick);
  }

  function startAnim() {
    if (rafId != null) return;
    lastFrameTs = 0;
    rafId = requestAnimationFrame(tick);
  }

  function stopAnim() {
    if (rafId != null) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
  }

  function onPlay() {
    playing = true;
    startAnim();
  }

  function onPause() {
    playing = false;
    stopAnim();
    drawWaveform(); // snap to current position
  }

  function onTimeUpdate() {
    if (!audioEl) return;
    currentTime = audioEl.currentTime;
    // If not animating (paused seek), still redraw to reflect the
    // playhead overlay position.
    if (!playing) drawWaveform();
  }

  function onLoadedMetadata() {
    if (!audioEl) return;
    duration = isFinite(audioEl.duration) && audioEl.duration > 0
      ? audioEl.duration
      : (media.meta as { duration?: number } | undefined)?.duration ?? 0;
  }

  function togglePlay(e: MouseEvent) {
    e.stopPropagation();
    if (!audioEl) return;
    if (playing) audioEl.pause();
    else void audioEl.play();
  }

  function stop(e: MouseEvent) {
    e.stopPropagation();
    if (!audioEl) return;
    audioEl.pause();
    audioEl.currentTime = 0;
  }

  function cycleSpeed(e: MouseEvent) {
    e.stopPropagation();
    const idx = SPEEDS.indexOf(speed);
    speed = SPEEDS[(idx + 1) % SPEEDS.length];
    if (audioEl) audioEl.playbackRate = speed;
  }

  function seekToEvent(e: MouseEvent) {
    e.stopPropagation();
    if (!audioEl || !duration) return;
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const x = e.clientX - rect.left;
    const ratio = Math.max(0, Math.min(1, x / rect.width));
    audioEl.currentTime = ratio * duration;
  }

  // Clicks anywhere inside the player (labels, waveform, dead space)
  // must not bubble up — the enclosing PostCard treats a card click
  // as "open the post detail", which would navigate away mid-seek.
  function swallowClick(e: MouseEvent) {
    e.stopPropagation();
  }

  function formatTime(seconds: number): string {
    if (!isFinite(seconds) || seconds < 0) return '--:--';
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  }

  let resizeObs: ResizeObserver | null = null;

  onMount(() => {
    loadWaveform();

    if (canvasEl && typeof ResizeObserver !== 'undefined') {
      resizeObs = new ResizeObserver(() => drawWaveform());
      resizeObs.observe(canvasEl);
    }
  });

  onDestroy(() => {
    resizeObs?.disconnect();
    stopAnim();
  });

  let displayName = $derived(author?.display_name || author?.handle || 'Unknown');
  let displayHandle = $derived(author?.acct || author?.handle || 'unknown');
  let progressPct = $derived(duration > 0 ? (currentTime / duration) * 100 : 0);
</script>

<div
  class="ap-pill"
  onclick={swallowClick}
  onkeydown={(e) => { if (e.key === 'Enter' || e.key === ' ') e.stopPropagation(); }}
  role="group"
  aria-label="Audio player"
  tabindex="-1"
>
  <audio
    bind:this={audioEl}
    src={media.url}
    preload="metadata"
    crossorigin="anonymous"
    onplay={onPlay}
    onpause={onPause}
    onended={onPause}
    ontimeupdate={onTimeUpdate}
    onloadedmetadata={onLoadedMetadata}
    aria-label={media.description || 'Audio attachment'}
  ></audio>

  <div class="ap-header">
    <div class="ap-avatar-wrap">
      <Avatar src={author?.avatar_url} name={displayName} size="sm" />
    </div>
    <div class="ap-titles">
      <span class="ap-title">Audio Broadcast</span>
      <span class="ap-handle">@{displayHandle}</span>
    </div>
  </div>

  <div class="ap-wave-wrap" class:ap-wave-loading={!peaksLoaded}>
    <canvas bind:this={canvasEl} class="ap-wave"></canvas>
  </div>

  <button type="button" class="ap-seek" onclick={seekToEvent} aria-label="Seek">
    <div class="ap-seek-fill" style:width="{progressPct}%"></div>
  </button>

  <div class="ap-controls">
    <div class="ap-controls-center">
      <button type="button" class="ap-btn" onclick={togglePlay} aria-label={playing ? 'Pause' : 'Play'}>
        <span class="material-symbols-outlined">{playing ? 'pause' : 'play_arrow'}</span>
      </button>
      <button type="button" class="ap-btn ap-btn-sm" onclick={stop} aria-label="Stop">
        <span class="material-symbols-outlined">stop</span>
      </button>
    </div>
    <div class="ap-meta">
      <button type="button" class="ap-speed" onclick={cycleSpeed} aria-label="Playback speed">{speed}x</button>
      <span class="ap-time">{formatTime(currentTime)} / {formatTime(duration)}</span>
    </div>
  </div>
</div>

<style>
  .ap-pill {
    --ap-bg: #0b0e11;
    --ap-border: rgba(97, 226, 255, 0.12);
    --ap-text: #e6f2f5;
    --ap-text-dim: rgba(230, 242, 245, 0.55);
    --ap-accent: #61e2ff;
    --ap-accent-deep: #174355;

    width: 100%;
    box-sizing: border-box;
    background:
      linear-gradient(180deg, rgba(23, 67, 85, 0.14) 0%, rgba(11, 14, 17, 0) 60%),
      var(--ap-bg);
    border: 1px solid var(--ap-border);
    border-radius: 18px;
    padding: 14px 18px 12px;
    color: var(--ap-text);
    display: flex;
    flex-direction: column;
    gap: 10px;
    backdrop-filter: saturate(1.3) blur(6px);
    -webkit-backdrop-filter: saturate(1.3) blur(6px);
    box-shadow: 0 6px 24px rgba(0, 0, 0, 0.22);
  }

  .ap-header {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  /* Wrap the Avatar component so we can force the small player
     avatar size — Avatar uses its own `size` prop but adding a
     wrap lets us override border/shadow for the on-dark theme. */
  .ap-avatar-wrap {
    display: inline-flex;
    border-radius: 9999px;
    box-shadow: 0 0 0 1px rgba(97, 226, 255, 0.18);
  }

  .ap-titles {
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
  }

  .ap-title {
    font-weight: 700;
    font-size: 0.85rem;
    letter-spacing: 0.01em;
    font-family: 'IBM Plex Sans', 'Vazirmatn', system-ui, sans-serif;
  }

  .ap-handle {
    font-size: 0.72rem;
    color: var(--ap-text-dim);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .ap-wave-wrap {
    height: 92px;
    position: relative;
    border-radius: 10px;
    background: linear-gradient(180deg, rgba(23, 67, 85, 0.08), rgba(11, 14, 17, 0));
    overflow: hidden;
    transition: opacity 400ms ease;
  }

  .ap-wave-loading {
    opacity: 0.35;
  }

  .ap-wave {
    display: block;
    width: 100%;
    height: 100%;
  }

  .ap-seek {
    appearance: none;
    background: none;
    border: none;
    padding: 0;
    cursor: pointer;
    width: 100%;
    height: 4px;
    border-radius: 2px;
    background: rgba(97, 226, 255, 0.1);
    position: relative;
    overflow: hidden;
  }

  .ap-seek-fill {
    position: absolute;
    inset-inline-start: 0;
    inset-block-start: 0;
    height: 100%;
    background: linear-gradient(90deg, var(--ap-accent-deep), var(--ap-accent));
    transition: width 120ms linear;
  }

  .ap-controls {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-block-start: 2px;
  }

  .ap-controls-center {
    display: inline-flex;
    gap: 4px;
    margin-inline: auto;
  }

  .ap-btn {
    appearance: none;
    background: rgba(97, 226, 255, 0.08);
    border: 1px solid rgba(97, 226, 255, 0.12);
    color: var(--ap-text);
    width: 36px;
    height: 36px;
    border-radius: 9999px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    transition: background 150ms ease, border-color 150ms ease;
  }

  .ap-btn:hover {
    background: rgba(97, 226, 255, 0.16);
    border-color: rgba(97, 226, 255, 0.25);
  }

  .ap-btn-sm {
    width: 30px;
    height: 30px;
    color: var(--ap-text-dim);
  }

  .ap-btn :global(.material-symbols-outlined) {
    font-size: 18px;
  }

  .ap-meta {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    font-size: 0.72rem;
    color: var(--ap-text-dim);
    font-variant-numeric: tabular-nums;
    font-family: 'IBM Plex Mono', 'JetBrains Mono', monospace;
  }

  .ap-speed {
    appearance: none;
    background: rgba(97, 226, 255, 0.05);
    border: 1px solid rgba(97, 226, 255, 0.1);
    color: var(--ap-accent);
    border-radius: 9999px;
    padding: 2px 8px;
    cursor: pointer;
    font-weight: 600;
    font-size: 0.7rem;
  }

  .ap-speed:hover {
    background: rgba(97, 226, 255, 0.1);
  }

  .ap-time {
    color: var(--ap-text-dim);
  }

  @media (prefers-reduced-motion: reduce) {
    .ap-wave-wrap,
    .ap-seek-fill {
      transition: none;
    }
  }
</style>
