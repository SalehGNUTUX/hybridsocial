<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import type { MediaAttachment, Identity } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';

  // Audio player with an iOS/macOS-style bar waveform. Idle, it shows the
  // amplitude envelope baked from the decoded PCM (real per-slice
  // loudness, never synthetic) with a progress fill. While playing, the
  // same bars are driven by a live Web Audio AnalyserNode, so they react
  // to the voice in real time — every bar is real signal, not animation.

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
  // Source resolution we bake from the decoded clip. The number of bars
  // actually drawn is derived from the canvas width; this is just the
  // envelope we resample down from.
  const BIN_COUNT = 400;

  let rafId: number | null = null;

  // Live Web Audio analyser, built lazily on first play (an AudioContext
  // needs a user gesture, and a MediaElementSource can be created only
  // once per <audio> element). While playing, the bars are driven by this
  // real-time spectrum so the waveform genuinely reacts to the voice;
  // paused/idle, we fall back to the baked envelope + progress.
  let liveCtx: AudioContext | null = null;
  let liveAnalyser: AnalyserNode | null = null;
  // Concrete ArrayBuffer backing so it satisfies getByteFrequencyData's
  // Uint8Array<ArrayBuffer> param under the generic lib.dom typings.
  let liveData: Uint8Array<ArrayBuffer> | null = null;
  let liveSmooth: Float32Array | null = null;
  // Set once we see any non-zero analyser frame. If it stays false the
  // media is CORS-tainted (analysis is all zeros) — we then keep showing
  // the honest static envelope instead of a dead flat line.
  let liveSeen = false;

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
      // Normalise 0..1 against the loudest slice. Keep a tiny floor so
      // silent gaps still read as small dashes (like a voice memo) —
      // every value here is measured amplitude, never synthetic.
      peaks = result.map((v) => Math.max(0.02, v / max));
      peaksLoaded = true;
      try { await ctx.close(); } catch { /* ignore */ }
      drawWaveform();
    } catch {
      // Decode failed (CORS / unsupported codec). Render a flat minimal
      // baseline rather than a fake waveform — bars must reflect real
      // audio only, so we show "no data" honestly instead of inventing peaks.
      peaks = new Array(BIN_COUNT).fill(0.03);
      peaksLoaded = true;
      drawWaveform();
    }
  }

  // Pull a fresh real-time frequency frame, exponentially smoothed so
  // bars glide rather than strobe. Returns the useful lower portion of
  // the spectrum (voice/music energy), or null while the signal is still
  // all-zero (CORS taint / pre-audio) so the caller can fall back.
  function sampleLive(): Float32Array | null {
    if (!liveAnalyser || !liveData || !liveSmooth) return null;
    liveAnalyser.getByteFrequencyData(liveData);
    const a = 0.5;
    let peak = 0;
    for (let i = 0; i < liveSmooth.length; i++) {
      const v = liveData[i] / 255;
      if (v > peak) peak = v;
      liveSmooth[i] = liveSmooth[i] * (1 - a) + v * a;
    }
    if (peak > 0.01) liveSeen = true;
    if (!liveSeen) return null;
    // Lower ~55% of bins carry essentially all the audible energy; the
    // top end is a dead flat tail, so crop it and stretch the useful
    // part across the full bar row.
    const useful = Math.max(1, Math.floor(liveSmooth.length * 0.55));
    return liveSmooth.subarray(0, useful);
  }

  // Draw one rounded, vertically-centred bar filled with a vertical
  // gradient that's solid at the centre line and fades out toward the top
  // and bottom tips — a soft, glowing look instead of hard-edged bars.
  function fadeBar(
    ctx: CanvasRenderingContext2D,
    x: number,
    midY: number,
    half: number,
    bw: number,
    rgb: string,
    alpha: number,
  ) {
    const yTop = midY - half;
    const bh = half * 2;
    const g = ctx.createLinearGradient(0, yTop, 0, midY + half);
    g.addColorStop(0, `rgba(${rgb}, ${alpha * 0.05})`);
    g.addColorStop(0.5, `rgba(${rgb}, ${alpha})`);
    g.addColorStop(1, `rgba(${rgb}, ${alpha * 0.05})`);
    ctx.fillStyle = g;
    const r = Math.min(bw / 2, half);
    if (typeof ctx.roundRect === 'function') {
      ctx.beginPath();
      ctx.roundRect(x, yTop, bw, bh, r);
      ctx.fill();
    } else {
      ctx.fillRect(x, yTop, bw, bh);
    }
  }

  // iOS/macOS voice-memo waveform: vertically-centred rounded bars, one
  // per slot, each bar's height set by the REAL decoded amplitude for
  // that slice of the clip (resampled from `peaks`). Bars before the
  // playhead take the accent colour; the rest stay dimmed, and the bar
  // under the playhead gets a brief highlight while playing.
  function drawWaveform() {
    if (!canvasEl) return;
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

    // Thin bars with a small gap.
    const BAR_W = 2;
    const GAP = 2;
    const slot = BAR_W + GAP;
    const barCount = Math.max(1, Math.floor((w + GAP) / slot));
    const midY = h / 2;
    const maxHalf = h / 2 - 1;
    const minHalf = 1;

    const ACCENT = '97, 226, 255';
    const HEAD = '184, 242, 255';
    const DIM = '230, 242, 245';

    // While playing, drive the bars from the live spectrum so they react
    // to the voice in real time. Each bar tracks a band of the actual
    // signal — not a synthetic animation.
    const live = playing ? sampleLive() : null;
    if (live) {
      for (let i = 0; i < barCount; i++) {
        const b0 = Math.floor((i / barCount) * live.length);
        const b1 = Math.min(
          live.length,
          Math.max(b0 + 1, Math.ceil(((i + 1) / barCount) * live.length)),
        );
        let sum = 0;
        for (let j = b0; j < b1; j++) sum += live[j];
        const amp = sum / (b1 - b0);
        const half = Math.max(minHalf, Math.pow(amp, 0.85) * maxHalf);
        fadeBar(ctx, i * slot, midY, half, BAR_W, ACCENT, 1);
      }
    } else if (peaks.length > 0) {
      const progress = duration > 0 ? Math.min(1, Math.max(0, currentTime / duration)) : 0;
      const playhead = progress * barCount;
      const headIdx = Math.floor(playhead);

      for (let i = 0; i < barCount; i++) {
        // Average the real envelope samples falling in this bar's slice —
        // no interpolation-invented values, just measured amplitude.
        const a0 = Math.floor((i / barCount) * peaks.length);
        const a1 = Math.min(
          peaks.length,
          Math.max(a0 + 1, Math.ceil(((i + 1) / barCount) * peaks.length)),
        );
        let sum = 0;
        for (let j = a0; j < a1; j++) sum += peaks[j];
        const amp = sum / (a1 - a0);

        // Mild perceptual curve (as iOS does): gently compress the dynamic
        // range so quiet-but-present passages stay visible next to the
        // peaks, while keeping the pronounced silent gaps.
        const half = Math.max(minHalf, Math.pow(amp, 0.72) * maxHalf);

        if (i < headIdx) fadeBar(ctx, i * slot, midY, half, BAR_W, ACCENT, 1);
        else if (playing && i === headIdx) fadeBar(ctx, i * slot, midY, half, BAR_W, HEAD, 1);
        else fadeBar(ctx, i * slot, midY, half, BAR_W, DIM, 0.28);
      }
    } else {
      return;
    }

    // Fade the whole row out at the left and right ends so it doesn't butt
    // hard against the container edges. One destination-in pass masks the
    // already-drawn bars by a horizontal alpha ramp.
    ctx.globalCompositeOperation = 'destination-in';
    const edge = 0.12;
    const mask = ctx.createLinearGradient(0, 0, w, 0);
    mask.addColorStop(0, 'rgba(0, 0, 0, 0)');
    mask.addColorStop(edge, 'rgba(0, 0, 0, 1)');
    mask.addColorStop(1 - edge, 'rgba(0, 0, 0, 1)');
    mask.addColorStop(1, 'rgba(0, 0, 0, 0)');
    ctx.fillStyle = mask;
    ctx.fillRect(0, 0, w, h);
    ctx.globalCompositeOperation = 'source-over';
  }

  // While playing, redraw each frame so the played-bar fill and the
  // playhead highlight advance smoothly. Cheap — just a few dozen
  // rounded rects per frame. Paused state stays frozen.
  function tick() {
    if (!playing) return;
    drawWaveform();
    rafId = requestAnimationFrame(tick);
  }

  function startAnim() {
    if (rafId != null) return;
    rafId = requestAnimationFrame(tick);
  }

  function stopAnim() {
    if (rafId != null) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
  }

  // Build the live-analysis graph on first play. Must run from the play
  // click's gesture stack or the AudioContext starts suspended. The
  // MediaElementSource can only be attached ONCE per <audio> element, so
  // we stash the handles and reuse them on every subsequent play.
  function ensureLiveGraph() {
    if (liveAnalyser || !audioEl) return;
    const Ctx = (window.AudioContext ||
      (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext) as
      | typeof AudioContext
      | undefined;
    if (!Ctx) return;
    try {
      liveCtx = new Ctx();
      const src = liveCtx.createMediaElementSource(audioEl);
      liveAnalyser = liveCtx.createAnalyser();
      liveAnalyser.fftSize = 512;
      liveAnalyser.smoothingTimeConstant = 0.7;
      // src → analyser → destination. Without the destination hop the
      // element would be silent (we've intercepted its default output).
      src.connect(liveAnalyser);
      liveAnalyser.connect(liveCtx.destination);
      liveData = new Uint8Array(liveAnalyser.frequencyBinCount);
      liveSmooth = new Float32Array(liveAnalyser.frequencyBinCount);
    } catch {
      // MediaElementSource failed (already connected on HMR, etc.) —
      // playback still works, the bars just fall back to the envelope.
      liveCtx = null;
      liveAnalyser = null;
      liveData = null;
      liveSmooth = null;
    }
  }

  function onPlay() {
    playing = true;
    ensureLiveGraph();
    // Resume if the context was auto-suspended (tab backgrounded, etc.).
    if (liveCtx && liveCtx.state === 'suspended') void liveCtx.resume();
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

  // Seek on pointer DOWN (not click): a click needs a down+up on the same
  // pixels, which is unreliable on a thin bar — pointerdown fires on the
  // press so a single tap always registers. Capturing the pointer lets the
  // user drag to scrub even if they slide off the (short) bar vertically.
  function seekToRatio(clientX: number, el: HTMLElement) {
    if (!audioEl || !duration) return;
    const rect = el.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
    audioEl.currentTime = ratio * duration;
  }

  function seekDown(e: PointerEvent) {
    e.stopPropagation();
    const el = e.currentTarget as HTMLElement;
    el.setPointerCapture?.(e.pointerId);
    seekToRatio(e.clientX, el);
  }

  function seekMove(e: PointerEvent) {
    // Only while the button is held (dragging to scrub).
    if (e.buttons !== 1) return;
    e.stopPropagation();
    seekToRatio(e.clientX, e.currentTarget as HTMLElement);
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
  let visibilityObs: IntersectionObserver | null = null;
  let containerEl: HTMLElement | undefined = $state();

  onMount(() => {
    loadWaveform();

    if (canvasEl && typeof ResizeObserver !== 'undefined') {
      resizeObs = new ResizeObserver(() => drawWaveform());
      resizeObs.observe(canvasEl);
    }

    // Auto-pause when the player scrolls out of view. A feed of
    // audio posts where the user has hit play on one and scrolled
    // away shouldn't keep talking — once paused, the user has to
    // manually resume.
    if (containerEl && typeof IntersectionObserver !== 'undefined') {
      visibilityObs = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (entry.isIntersecting) continue;
            if (!audioEl) continue;
            if (audioEl.paused || audioEl.ended) continue;
            audioEl.pause();
          }
        },
        { threshold: 0.1 },
      );
      visibilityObs.observe(containerEl);
    }
  });

  onDestroy(() => {
    resizeObs?.disconnect();
    visibilityObs?.disconnect();
    stopAnim();
    // Close the AudioContext so it doesn't leak or keep the tab's audio
    // indicator lit after the player unmounts.
    if (liveCtx) {
      try { void liveCtx.close(); } catch { /* ignore */ }
      liveCtx = null;
      liveAnalyser = null;
      liveData = null;
      liveSmooth = null;
    }
  });

  let displayName = $derived(author?.display_name || author?.handle || 'Unknown');
  let displayHandle = $derived(author?.acct || author?.handle || 'unknown');
  let progressPct = $derived(duration > 0 ? (currentTime / duration) * 100 : 0);
</script>

<div
  bind:this={containerEl}
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

  <button
    type="button"
    class="ap-seek"
    onpointerdown={seekDown}
    onpointermove={seekMove}
    aria-label="Seek"
  >
    <span class="ap-seek-track">
      <span class="ap-seek-fill" style:width="{progressPct}%"></span>
    </span>
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
    height: 54px;
    position: relative;
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

  /* Tall, full-width hit area so a click anywhere on the strip seeks —
     the visible track is a thin bar centred inside it. */
  .ap-seek {
    appearance: none;
    background: none;
    border: none;
    padding: 0;
    margin: 0;
    cursor: pointer;
    width: 100%;
    height: 18px;
    display: flex;
    align-items: center;
    touch-action: none;
  }

  .ap-seek-track {
    position: relative;
    width: 100%;
    height: 4px;
    border-radius: 2px;
    background: rgba(97, 226, 255, 0.1);
    overflow: hidden;
    /* Let all pointer events fall through to the button so its rect (and
       full width) is always the seek reference. */
    pointer-events: none;
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
