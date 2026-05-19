<script lang="ts">
  // Touch-only reaction dial. Lives as an overlay over the whole
  // viewport; PostActions owns the touch handlers and tells us where
  // the user's finger currently is. We figure out which emoji that
  // angle picks and bubble it back through `bind:highlightedType` so
  // the parent can commit it on touchend.

  interface RadialReaction {
    type: string;
    emoji: string;
    label: string;
    image?: string | null;
  }

  let {
    originX,
    originY,
    touchX,
    touchY,
    reactions,
    highlightedType = $bindable<string | null>(null),
  }: {
    originX: number;
    originY: number;
    touchX: number;
    touchY: number;
    reactions: RadialReaction[];
    highlightedType?: string | null;
  } = $props();

  // Pixel distance the finger has to travel from the origin before
  // any emoji is considered "aimed at". Under this radius, releasing
  // cancels the reaction — same UX as the iOS message tapback dial.
  const DEAD_ZONE_PX = 36;
  // Safety gutter from each viewport edge — bubbles never sit closer
  // to the screen edge than `halfItem + EDGE_MARGIN` so the rounded
  // bubble graphic never gets clipped.
  const EDGE_MARGIN = 6;

  // The arc radius, item size, and angular sweep scale with reaction
  // count so a 14-emoji dial (premium tier) doesn't overlap itself.
  // We keep the radius small enough that the arc sits visibly close
  // to the finger rather than ballooning out across the viewport.
  let arcRadius = $derived.by(() => {
    const n = Math.max(reactions.length, 1);
    if (n <= 7) return 88;
    return Math.min(88 + (n - 7) * 7, 130);
  });
  let itemSize = $derived(reactions.length > 10 ? 40 : 46);
  let emojiSize = $derived(reactions.length > 10 ? 22 : 26);

  // Angular sweep — widen it slightly when there are many reactions
  // so neighbours don't crowd each other. Anything wider than 180°
  // dips a bit below horizontal at the ends, which is fine because
  // the cancel threshold is computed from the arc's lowest point.
  let sweepDeg = $derived(reactions.length <= 7 ? 180 : 200);

  // Tilt the arc center away from whichever vertical edge the trigger
  // sits closest to. A like button rendered against the right edge of
  // the viewport (common on RTL feeds and on narrow phones) would
  // otherwise put half its emojis off-screen — see the screenshot in
  // the 2026-05-19 bug report. ratio=0 (left edge) tilts the arc to
  // the upper-right; ratio=1 (right edge) tilts it to the upper-left;
  // ratio=0.5 keeps it pointing straight up.
  let arcCenterDeg = $derived.by(() => {
    if (typeof window === 'undefined') return 270;
    const ratio = Math.max(0, Math.min(1, originX / window.innerWidth));
    return 330 - 120 * ratio;
  });

  let arcStart = $derived(arcCenterDeg - sweepDeg / 2);
  let arcEnd = $derived(arcCenterDeg + sweepDeg / 2);

  // How far below the origin the lowest emoji in the arc sits. Used
  // to set the cancel-on-drag-down threshold so it stays just under
  // the arc rather than slicing through it on wider sweeps.
  let arcLowestY = $derived.by(() => {
    const sStart = Math.sin((arcStart * Math.PI) / 180);
    const sEnd = Math.sin((arcEnd * Math.PI) / 180);
    return Math.max(0, Math.max(sStart, sEnd) * arcRadius);
  });

  let positions = $derived.by(() => {
    const n = reactions.length;
    if (n === 0) return [];
    const vw = typeof window !== 'undefined' ? window.innerWidth : 9999;
    const vh = typeof window !== 'undefined' ? window.innerHeight : 9999;
    const margin = itemSize / 2 + EDGE_MARGIN;
    const step = n === 1 ? 0 : (arcEnd - arcStart) / (n - 1);
    return reactions.map((r, i) => {
      // Normalize to [0, 360) so the hit-test comparison against
      // touchDeg (also normalized) doesn't need wrap-around special
      // cases when arcEnd > 360 or arcStart < 0.
      const rawDeg = n === 1 ? arcCenterDeg : arcStart + i * step;
      const deg = ((rawDeg % 360) + 360) % 360;
      const rad = (rawDeg * Math.PI) / 180;
      const rawX = originX + arcRadius * Math.cos(rad);
      const rawY = originY + arcRadius * Math.sin(rad);
      // Clamp display position to viewport. Hit-detection still uses
      // the unclamped angle from the origin, so visually clipping the
      // bubble to the screen edge doesn't break which emoji a touch
      // resolves to.
      const x = Math.min(Math.max(rawX, margin), vw - margin);
      const y = Math.min(Math.max(rawY, margin), vh - margin);
      return { ...r, x, y, deg };
    });
  });

  // Index of the emoji the finger is currently pointing at, or -1
  // when the finger is too close to the origin (dead zone) or below
  // the arc — both signal "cancel".
  let activeIdx = $derived.by(() => {
    if (positions.length === 0) return -1;
    const dx = touchX - originX;
    const dy = touchY - originY;
    const dist = Math.hypot(dx, dy);
    if (dist < DEAD_ZONE_PX) return -1;

    // Cancel if the finger has wandered well below the dial. Use the
    // arc's actual lowest y so a wider sweep doesn't trip this guard.
    if (dy > arcLowestY + 28) return -1;

    // Pick the emoji whose angular position is closest to the finger.
    // Atan2 returns [-180°, 180°]; normalize to [0, 360°) so the
    // comparison with `positions[i].deg` is direct.
    const touchDeg = ((Math.atan2(dy, dx) * 180) / Math.PI + 360) % 360;
    let best = -1;
    let bestDiff = Infinity;
    for (let i = 0; i < positions.length; i++) {
      let diff = Math.abs(positions[i].deg - touchDeg);
      if (diff > 180) diff = 360 - diff;
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  });

  $effect(() => {
    highlightedType = activeIdx >= 0 ? positions[activeIdx].type : null;
  });

  // Mild haptic each time the highlighted emoji changes — gives the
  // user tactile confirmation as their finger sweeps across the arc.
  // Gracefully no-ops on iOS Safari, which doesn't expose vibrate().
  let lastHaptic = -1;
  $effect(() => {
    if (activeIdx !== lastHaptic) {
      lastHaptic = activeIdx;
      if (activeIdx >= 0 && typeof navigator !== 'undefined' && navigator.vibrate) {
        navigator.vibrate(8);
      }
    }
  });

  // Label sits just past the arc in the direction the arc points
  // (i.e. opposite the trigger). Clamped to the viewport so a label
  // for a long reaction shortcode never bleeds off-screen.
  let labelPos = $derived.by(() => {
    const vw = typeof window !== 'undefined' ? window.innerWidth : 9999;
    const rad = (arcCenterDeg * Math.PI) / 180;
    const dist = arcRadius + 36;
    const rawX = originX + dist * Math.cos(rad);
    const rawY = originY + dist * Math.sin(rad);
    return {
      x: Math.min(Math.max(rawX, 70), vw - 70),
      y: Math.max(rawY, 16),
    };
  });
</script>

<div class="radial-overlay" aria-hidden="true">
  <!-- Soft scrim so the underlying post fades a touch — makes the
       dial easier to focus on without obscuring the post entirely. -->
  <div class="radial-scrim"></div>

  <!-- Faint guide ring to anchor the eye on the arc center. -->
  <div
    class="radial-ring"
    style="left: {originX}px; top: {originY}px; width: {arcRadius * 2}px; height: {arcRadius * 2}px;"
  ></div>

  {#each positions as p, i (p.type)}
    <div
      class="radial-item"
      class:radial-item-active={i === activeIdx}
      style="left: {p.x}px; top: {p.y}px; width: {itemSize}px; height: {itemSize}px; animation-delay: {30 * i}ms;"
    >
      {#if p.image}
        <img class="radial-image" src={p.image} alt="" style="width: {emojiSize}px; height: {emojiSize}px;" />
      {:else}
        <span class="radial-emoji" style="font-size: {emojiSize}px;">{p.emoji}</span>
      {/if}
    </div>
  {/each}

  <!-- Label tag at the top of the dial showing what the user is
       about to pick. Hidden when in the dead zone so the user clearly
       sees they're cancelling. Position keeps it out of the finger's
       path and is clamped inside the viewport. -->
  {#if activeIdx >= 0}
    {@const label = positions[activeIdx].label}
    <div
      class="radial-label"
      style="left: {labelPos.x}px; top: {labelPos.y}px;"
    >
      {label}
    </div>
  {/if}
</div>

<style>
  .radial-overlay {
    position: fixed;
    inset: 0;
    z-index: 10000;
    /* Don't intercept touches — the like button's touchmove handler
       is the source of truth for where the finger is, and we don't
       want this overlay to swallow that event. */
    pointer-events: none;
  }

  .radial-scrim {
    position: absolute;
    inset: 0;
    background: rgba(0, 0, 0, 0.18);
    backdrop-filter: blur(1px);
    -webkit-backdrop-filter: blur(1px);
    animation: scrim-in 120ms ease forwards;
  }

  .radial-ring {
    position: absolute;
    transform: translate(-50%, -50%);
    /* width / height are set inline; they scale with reaction count. */
    border-radius: 50%;
    border: 1px dashed rgba(255, 255, 255, 0.18);
    pointer-events: none;
    animation: ring-in 220ms cubic-bezier(0.22, 1, 0.36, 1) forwards;
  }

  .radial-item {
    position: absolute;
    transform: translate(-50%, -50%) scale(0);
    /* width / height are set inline; they scale with reaction count. */
    border-radius: 50%;
    background: var(--color-surface-container-lowest, #fff);
    display: flex;
    align-items: center;
    justify-content: center;
    box-shadow: 0 6px 16px rgba(0, 0, 0, 0.18);
    /* `opacity` doesn't transition cleanly with the pop animation;
       set start state via animation and let `transition` handle the
       active-scale-up afterward. */
    animation: pop-in 220ms cubic-bezier(0.22, 1, 0.36, 1) both;
    transition: transform 120ms cubic-bezier(0.34, 1.56, 0.64, 1),
      background 120ms ease,
      box-shadow 120ms ease;
  }

  .radial-item-active {
    transform: translate(-50%, -50%) scale(1.5);
    background: var(--color-primary-soft, #e0f2fe);
    box-shadow: 0 10px 26px rgba(0, 0, 0, 0.32);
    z-index: 1;
  }

  .radial-emoji {
    /* font-size is set inline; it scales with reaction count. */
    line-height: 1;
  }

  .radial-image {
    /* width / height are set inline; they scale with reaction count. */
    object-fit: contain;
  }

  .radial-label {
    position: absolute;
    transform: translate(-50%, -50%);
    padding: 4px 10px;
    font-size: 13px;
    font-weight: 600;
    color: #fff;
    background: rgba(0, 0, 0, 0.7);
    border-radius: 9999px;
    pointer-events: none;
    white-space: nowrap;
  }

  @keyframes scrim-in {
    from { opacity: 0; }
    to { opacity: 1; }
  }

  @keyframes ring-in {
    from { opacity: 0; transform: translate(-50%, -50%) scale(0.6); }
    to { opacity: 1; transform: translate(-50%, -50%) scale(1); }
  }

  @keyframes pop-in {
    from { opacity: 0; transform: translate(-50%, -50%) scale(0); }
    60% { opacity: 1; transform: translate(-50%, -50%) scale(1.15); }
    to { opacity: 1; transform: translate(-50%, -50%) scale(1); }
  }
</style>
