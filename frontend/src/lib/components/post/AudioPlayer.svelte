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
  const STRAND_COUNT = 7;

  let rafId: number | null = null;
  let animPhase = 0;
  let lastFrameTs = 0;

  // Live-analysis graph. Wired lazily on first play so we don't
  // create an AudioContext before a user gesture (Chrome blocks
  // autoplay contexts otherwise). MediaElementSource can only be
  // constructed ONCE per element, so we keep the handles around.
  let liveCtx: AudioContext | null = null;
  let liveAnalyser: AnalyserNode | null = null;
  let liveData: Uint8Array | null = null;
  // Low-passed version of the analyser data so strand heights don't
  // twitch frame-to-frame. Each bin decays toward the raw value with
  // a weight, giving a smoothed shimmer instead of a hard-edge
  // equalizer bounce.
  let liveSmooth: Float32Array | null = null;

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

  // Pull a fresh frame of live frequency data into `liveSmooth`,
  // applying exponential smoothing so bins don't flicker. Returns
  // a view onto the *useful* lower portion of the FFT — the upper
  // half of the spectrum is near-silent for speech/music at 44.1kHz
  // sample rate, which would render as a flat dead tail on the
  // right side of the waveform. Stretching only the lower bins
  // across the full canvas keeps every pixel reactive.
  function sampleLive(): Float32Array | null {
    if (!liveAnalyser || !liveData || !liveSmooth) return null;
    liveAnalyser.getByteFrequencyData(liveData);
    const a = 0.32;
    for (let i = 0; i < liveSmooth.length; i++) {
      const v = liveData[i] / 255;
      liveSmooth[i] = liveSmooth[i] * (1 - a) + v * a;
    }
    // Keep the lower ~40% of bins. With fftSize=512 that's 102 bins
    // covering 0 → ~9 kHz at 44.1 kHz — basically everything a
    // listener hears as "the sound", nothing past the hi-hat
    // sparkle range that tends to read as zero.
    const useful = Math.floor(liveSmooth.length * 0.4);
    return liveSmooth.subarray(0, useful);
  }

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

    // Prefer live analyser data when playing; fall back to the
    // pre-decoded envelope (peaks) otherwise. This gives a real-
    // time EQ-style shimmer during playback and a clean
    // full-track silhouette when idle.
    const live = playing ? sampleLive() : null;
    const envelope = live ?? Float32Array.from(peaks);
    if (envelope.length === 0) return;

    // Interlacing sine-strand render. Each strand is a smooth
    // curve centered on midY — amplitude comes from the signal
    // envelope (live FFT or pre-decoded peaks), frequency +
    // phase offsets per strand are what makes the bundle
    // interlace instead of tracking as one thick line. The
    // whole bundle spreads wider on loud sections and collapses
    // toward the centerline when quiet, like the reference.
    const midY = h / 2;
    const maxHalf = h / 2 - 3;
    // Sample the envelope at a denser resolution than its source
    // (linear interpolation) so strand curves stay smooth even
    // when the FFT crop gives us only ~100 bins.
    const SAMPLES = 220;

    for (let s = 0; s < STRAND_COUNT; s++) {
      const strandFrac = s / (STRAND_COUNT - 1 || 1);
      // Each strand gets a distinct sine frequency + phase so
      // they cross each other. Strand amplitudes are also
      // slightly different so you see depth in the bundle.
      const strandScale = 0.55 + 0.45 * Math.sin(strandFrac * Math.PI);
      const strandFreq = 0.06 + 0.012 * s; // radians per x pixel
      // Phase advance: unique speed per strand AND alternating
      // direction (odd strands drift right, even strands drift
      // left). Without the sign flip every strand's phase
      // increases monotonically and the bundle reads as a single
      // synchronized shift even at different speeds. With it, you
      // see strands crossing each other continuously — which is
      // what makes the bundle look alive vs. rigid.
      const strandSpeed = 0.5 + s * 0.28;
      const strandDir = s % 2 === 0 ? 1 : -1;
      const strandPhase =
        strandFrac * Math.PI * 2 + animPhase * strandSpeed * strandDir;

      ctx.lineWidth = 1;
      ctx.beginPath();
      for (let i = 0; i <= SAMPLES; i++) {
        const t = i / SAMPLES; // 0..1 across canvas
        const x = t * w;
        // Linear interp into the envelope for the local amplitude.
        const envPos = t * (envelope.length - 1);
        const envIdx = Math.floor(envPos);
        const envFrac = envPos - envIdx;
        const envA = envelope[envIdx] ?? 0;
        const envB = envelope[Math.min(envIdx + 1, envelope.length - 1)] ?? envA;
        const mag = Math.max(0.05, envA * (1 - envFrac) + envB * envFrac);
        // Sine curve for this strand at this x.
        const y = midY + Math.sin(x * strandFreq + strandPhase) * maxHalf * strandScale * mag;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      const grad = ctx.createLinearGradient(0, 0, w, 0);
      grad.addColorStop(0, `rgba(23, 67, 85, ${0.35 + strandFrac * 0.2})`);
      grad.addColorStop(1, `rgba(97, 226, 255, ${0.45 + strandFrac * 0.3})`);
      ctx.strokeStyle = grad;
      ctx.stroke();
    }

    // The seek bar below the canvas shows played progress; no
    // need to also overlay a played-region tint on the waveform
    // itself — it was reading as a clipped background rectangle.
  }

  // Lazily build the live-analysis graph on first play. Must run
  // from a user-gesture stack (the click that called .play()),
  // otherwise the AudioContext starts suspended and stays that
  // way. MediaElementSource can only be attached ONCE per
  // <audio> element, so we stash the handles and reuse them on
  // every subsequent play.
  function ensureLiveGraph() {
    if (liveAnalyser) return;
    if (!audioEl) return;
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
      liveAnalyser.smoothingTimeConstant = 0.6;
      // Source → analyser → destination. Without the destination
      // hop, playback would be silent because we've intercepted
      // the element's default output.
      src.connect(liveAnalyser);
      liveAnalyser.connect(liveCtx.destination);
      liveData = new Uint8Array(liveAnalyser.frequencyBinCount);
      liveSmooth = new Float32Array(liveAnalyser.frequencyBinCount);
    } catch {
      // MediaElementSource failed (CORS taint, or already-
      // connected element on HMR). Fall back to the static
      // pre-decoded envelope — the player still plays audio,
      // it just won't shimmer to the live signal.
      liveCtx = null;
      liveAnalyser = null;
      liveData = null;
      liveSmooth = null;
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
    ensureLiveGraph();
    // Resume if the context was suspended (page backgrounded, etc).
    if (liveCtx && liveCtx.state === 'suspended') {
      void liveCtx.resume();
    }
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
    // Tear the live graph down — leaving an AudioContext running
    // after the component unmounts leaks memory + keeps the tab's
    // audio indicator on.
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
