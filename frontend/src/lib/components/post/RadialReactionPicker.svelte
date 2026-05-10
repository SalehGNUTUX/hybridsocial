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
  const DEAD_ZONE_PX = 38;
  // Where the dial arc sits relative to the origin. Picked so that
  // with a typical action-bar height the arc fits on screen above
  // the like button on every phone we tested.
  const ARC_RADIUS = 108;
  // Emojis are laid out across the top semicircle (the half of the
  // dial that's above the button), so the user's thumb never has to
  // travel down into the bottom-tab-bar to reach a reaction. In
  // screen coords (y goes down) that's the angle range 180° → 360°.
  const ARC_START_DEG = 180;
  const ARC_END_DEG = 360;

  let positions = $derived.by(() => {
    const n = reactions.length;
    if (n === 0) return [];
    const step = n === 1 ? 0 : (ARC_END_DEG - ARC_START_DEG) / (n - 1);
    return reactions.map((r, i) => {
      const deg = n === 1 ? 270 : ARC_START_DEG + i * step;
      const rad = (deg * Math.PI) / 180;
      return {
        ...r,
        x: originX + ARC_RADIUS * Math.cos(rad),
        y: originY + ARC_RADIUS * Math.sin(rad),
        deg,
      };
    });
  });

  // Index of the emoji the finger is currently pointing at, or -1
  // when the finger is too close to the origin (dead zone) or below
  // the horizontal — both signal "cancel".
  let activeIdx = $derived.by(() => {
    if (positions.length === 0) return -1;
    const dx = touchX - originX;
    const dy = touchY - originY;
    const dist = Math.hypot(dx, dy);
    if (dist < DEAD_ZONE_PX) return -1;

    // The user's finger should be pointing into the upper semicircle
    // (the arc the emojis live on). If they've dragged below the
    // button, treat it as cancel — they're outside the dial.
    if (dy > 16) return -1;

    // Pick the emoji whose angular position is closest to the finger.
    // Atan2 returns [-180°, 180°]; normalize to [0, 360°) so the
    // comparison with `positions[i].deg` (which lives in [180°, 360°])
    // is direct.
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
</script>

<div class="radial-overlay" aria-hidden="true">
  <!-- Soft scrim so the underlying post fades a touch — makes the
       dial easier to focus on without obscuring the post entirely. -->
  <div class="radial-scrim"></div>

  <!-- Faint guide ring to anchor the eye on the arc center. -->
  <div
    class="radial-ring"
    style="left: {originX}px; top: {originY}px;"
  ></div>

  {#each positions as p, i (p.type)}
    <div
      class="radial-item"
      class:radial-item-active={i === activeIdx}
      style="left: {p.x}px; top: {p.y}px; animation-delay: {30 * i}ms;"
    >
      {#if p.image}
        <img class="radial-image" src={p.image} alt="" />
      {:else}
        <span class="radial-emoji">{p.emoji}</span>
      {/if}
    </div>
  {/each}

  <!-- Label tag above the dial showing what the user is about to pick.
       Hidden when in the dead zone so the user clearly sees they're
       cancelling. Position keeps it out of the finger's path. -->
  {#if activeIdx >= 0}
    {@const label = positions[activeIdx].label}
    <div
      class="radial-label"
      style="left: {originX}px; top: {originY - ARC_RADIUS - 36}px;"
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
    width: 216px;
    height: 216px;
    border-radius: 50%;
    border: 1px dashed rgba(255, 255, 255, 0.18);
    pointer-events: none;
    animation: ring-in 220ms cubic-bezier(0.22, 1, 0.36, 1) forwards;
  }

  .radial-item {
    position: absolute;
    transform: translate(-50%, -50%) scale(0);
    width: 48px;
    height: 48px;
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
    font-size: 28px;
    line-height: 1;
  }

  .radial-image {
    width: 28px;
    height: 28px;
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
