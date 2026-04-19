<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import type { MediaAttachment, Identity } from '$lib/api/types.js';

  // Waveform-visualized audio player styled to match the "Audio
  // Broadcast" design: dark glassmorphism pill, multi-strand teal→
  // cyan waveform, minimalist controls. Renders the waveform from
  // the actual audio via the Web Audio API — no external player
  // library — and gracefully degrades to a bar-strip visualization
  // if decoding fails (e.g. browser can't decode that codec).

  let {
    media,
    author
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
  const BIN_COUNT = 240;
  const STRAND_COUNT = 9;

  // Decode the audio to extract an envelope of peak amplitudes —
  // one value per bin. Runs in the background after mount; the UI
  // shows a flat bar until this completes, then animates in.
  async function loadWaveform() {
    if (!media.url) return;
    try {
      const res = await fetch(media.url, { credentials: 'omit' });
      if (!res.ok) return;
      const buf = await res.arrayBuffer();

      // Safari still ships webkitAudioContext on older versions;
      // the cast keeps TS happy without widening the window type.
      const Ctx = (window.AudioContext ||
        (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext) as
        | typeof AudioContext
        | undefined;
      if (!Ctx) return;
      const ctx = new Ctx();
      const audio = await ctx.decodeAudioData(buf);

      // Average absolute amplitude across channels per bin. A plain
      // max-abs would show isolated spikes as cliffs; RMS-ish gives
      // a more honest envelope for speech/music.
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

      // Normalize to [0,1] so varying input gains produce consistent
      // visual peaks. Clamp to a floor so a mostly-silent track
      // still shows SOMETHING rather than a flat line.
      const max = Math.max(...result, 0.001);
      peaks = result.map((v) => Math.max(0.08, v / max));
      peaksLoaded = true;
      try { await ctx.close(); } catch { /* ignore */ }
      drawWaveform();
    } catch {
      // Fall back to a synthetic envelope (sine-like) — better than
      // a dead component when decoding fails on some mobile browsers.
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

    // Draw STRAND_COUNT ultra-fine strands. Each strand is a
    // slightly jittered, vertically-scaled copy of the envelope.
    // Strands past the playhead render in a teal→cyan gradient;
    // strands before it render in a dimmed color to show progress.
    for (let s = 0; s < STRAND_COUNT; s++) {
      const strandPhase = (s / (STRAND_COUNT - 1)) * Math.PI;
      const strandScale = 0.5 + 0.5 * (s / (STRAND_COUNT - 1));

      ctx.lineWidth = 1;
      ctx.beginPath();
      for (let i = 0; i < peaks.length; i++) {
        const x = i * stepX;
        const jitter = Math.sin(i * 0.25 + strandPhase) * 0.6;
        const amp = peaks[i] * (midY - 4) * strandScale;
        const y = midY + jitter - amp;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      for (let i = peaks.length - 1; i >= 0; i--) {
        const x = i * stepX;
        const jitter = Math.sin(i * 0.25 + strandPhase) * 0.6;
        const amp = peaks[i] * (midY - 4) * strandScale;
        const y = midY + jitter + amp;
        ctx.lineTo(x, y);
      }
      ctx.closePath();

      // Gradient: deep teal at left, bright cyan at right. Played
      // portion is dimmed so progress is obvious without a hard
      // vertical playhead line.
      const grad = ctx.createLinearGradient(0, 0, w, 0);
      grad.addColorStop(0, `rgba(23, 67, 85, ${0.18 + (s / STRAND_COUNT) * 0.12})`);
      grad.addColorStop(1, `rgba(97, 226, 255, ${0.22 + (s / STRAND_COUNT) * 0.16})`);
      ctx.strokeStyle = grad;
      ctx.stroke();
    }

    // Played-region overlay: thin highlight band so the played
    // portion visually brightens without redrawing every strand twice.
    if (splitX > 0) {
      ctx.fillStyle = 'rgba(97, 226, 255, 0.06)';
      ctx.fillRect(0, 0, splitX, h);
    }
  }

  function onTimeUpdate() {
    if (!audioEl) return;
    currentTime = audioEl.currentTime;
    drawWaveform();
  }

  function onLoadedMetadata() {
    if (!audioEl) return;
    // Prefer the server-reported duration (MediaFile.duration) if
    // present — browsers sometimes report Infinity for streaming
    // containers until the file is fully downloaded.
    duration = isFinite(audioEl.duration) && audioEl.duration > 0
      ? audioEl.duration
      : (media.meta as { duration?: number } | undefined)?.duration ?? 0;
  }

  function togglePlay() {
    if (!audioEl) return;
    if (playing) {
      audioEl.pause();
    } else {
      void audioEl.play();
    }
  }

  function stop() {
    if (!audioEl) return;
    audioEl.pause();
    audioEl.currentTime = 0;
  }

  function cycleSpeed() {
    const idx = SPEEDS.indexOf(speed);
    speed = SPEEDS[(idx + 1) % SPEEDS.length];
    if (audioEl) audioEl.playbackRate = speed;
  }

  function seekToEvent(e: MouseEvent) {
    if (!audioEl || !duration) return;
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const x = e.clientX - rect.left;
    const ratio = Math.max(0, Math.min(1, x / rect.width));
    audioEl.currentTime = ratio * duration;
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

    // Redraw on container resize so the waveform stays crisp when
    // the user toggles a side panel or resizes the window.
    if (canvasEl && typeof ResizeObserver !== 'undefined') {
      resizeObs = new ResizeObserver(() => drawWaveform());
      resizeObs.observe(canvasEl);
    }
  });

  onDestroy(() => {
    resizeObs?.disconnect();
  });

  let avatarInitial = $derived((author?.display_name || author?.handle || '?').charAt(0).toUpperCase());
  let displayHandle = $derived(author?.acct || author?.handle || 'unknown');
  let progressPct = $derived(duration > 0 ? (currentTime / duration) * 100 : 0);
</script>

<div class="ap-pill">
  <audio
    bind:this={audioEl}
    src={media.url}
    preload="metadata"
    onplay={() => (playing = true)}
    onpause={() => (playing = false)}
    onended={() => (playing = false)}
    ontimeupdate={onTimeUpdate}
    onloadedmetadata={onLoadedMetadata}
    aria-label={media.description || 'Audio attachment'}
  ></audio>

  <div class="ap-header">
    {#if author?.avatar_url}
      <img class="ap-avatar" src={author.avatar_url} alt="" />
    {:else}
      <span class="ap-avatar ap-avatar-fallback">{avatarInitial}</span>
    {/if}
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

  .ap-avatar {
    width: 28px;
    height: 28px;
    border-radius: 9999px;
    object-fit: cover;
    background: rgba(97, 226, 255, 0.12);
    border: 1px solid rgba(97, 226, 255, 0.15);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 0.75rem;
    font-weight: 700;
    color: var(--ap-accent);
  }

  .ap-avatar-fallback {
    font-family: 'IBM Plex Sans', 'Vazirmatn', system-ui, sans-serif;
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
    height: 72px;
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
    height: 3px;
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

  .ap-btn .material-symbols-outlined {
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
