<script lang="ts">
  // Touch reaction tray. Replaces the earlier radial dial: a rounded
  // panel of emoji that pops above the like button with a pointer tail
  // aimed at it. A grid fits any reaction count (7 default, up to the
  // premium 14) at any screen width without the arc-vs-width overlap the
  // dial suffered. PostActions owns the touch handlers and passes the
  // button centre (originX/originY) and the live finger position; we map
  // that to a highlighted cell and bubble it back through
  // `bind:highlightedType`, and call `onpick` when a cell is tapped.

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
    onpick = undefined,
    armed = false,
    ondismiss = undefined,
  }: {
    originX: number;
    originY: number;
    touchX: number;
    touchY: number;
    reactions: RadialReaction[];
    highlightedType?: string | null;
    /** Called when an emoji is tapped/released on a cell. */
    onpick?: (type: string) => void;
    /** True once the long-press lifted without picking: the tray waits
        for a tap. In this state the overlay captures pointer events so a
        tap outside the tray dismisses it WITHOUT falling through to the
        post/link/button behind. During the initial drag (armed=false) the
        overlay stays pointer-transparent so the button's touch handlers
        still see the finger. */
    armed?: boolean;
    /** Called when the backdrop is tapped while armed — dismiss request. */
    ondismiss?: () => void;
  } = $props();

  // Device-verified fix: the tray positions itself in viewport
  // coordinates (position:fixed + getBoundingClientRect), but
  // `.post-card` carries a transform (its :hover lift, which sticks after
  // a tap on touch), and a transformed ancestor becomes the containing
  // block for fixed descendants — so the tray anchored to the post card
  // instead of the viewport and rendered detached / off-screen. Real
  // iPhone measurement: offsetParent was ARTICLE, position off by ~26px.
  // Portaling the overlay to <body> removes .post-card from its ancestor
  // chain, so `fixed` resolves against the viewport again (the same fix
  // EmojiPicker and the composer already use). body/html carry
  // overflow-x:clip but that does not reposition a fixed child — only the
  // transform did.
  function portal(node: HTMLElement) {
    document.body.appendChild(node);
    return {
      destroy() {
        node.remove();
      },
    };
  }

  const EDGE_MARGIN = 8;
  const GAP = 6;
  const PAD = 10;
  const BORDER = 1;

  // Cell size shrinks a touch for the dense premium set so two rows of
  // seven still fit comfortably on a 320px phone.
  // Up to 7 per row; a second row opens once we pass 7.
  let cols = $derived(Math.min(reactions.length, 7));
  let rows = $derived(Math.max(1, Math.ceil(reactions.length / 7)));

  // Cell size: a comfortable default, but never so large that the row
  // overflows the viewport. On a 320px phone the 7-wide premium row must
  // still fit inside the edge margins, so we cap the cell to the width
  // the screen can actually give each column.
  let cellSize = $derived.by(() => {
    const preferred = reactions.length <= 7 ? 46 : 44;
    const vw = typeof window !== 'undefined' ? window.innerWidth : 400;
    const available = vw - EDGE_MARGIN * 2 - PAD * 2 - BORDER * 2 - GAP * (cols - 1);
    const maxCell = Math.floor(available / cols);
    return Math.max(30, Math.min(preferred, maxCell));
  });

  // Exact rendered box: fixed-size cells + gaps + padding + the 1px
  // border on each side. Used for centering the tray on the button and
  // for placing the tail; the tray element itself is NOT given this as
  // an explicit width — it sizes to its grid content so left/right
  // padding stay symmetric (an explicit width that didn't match the
  // content to the pixel pooled the slack on one side).
  let trayWidth = $derived(cols * cellSize + (cols - 1) * GAP + PAD * 2 + BORDER * 2);
  let trayHeight = $derived(rows * cellSize + (rows - 1) * GAP + PAD * 2 + BORDER * 2);

  // Position the tray relative to the button. It prefers to sit above,
  // but flips below when there isn't room above (button near the top of
  // the screen) — otherwise the tray rendered at a short/negative top and
  // appeared detached from the post. Whichever side is chosen, the tail
  // stays pinned to the button centre so the pointer always aims at it,
  // even when the tray itself had to slide inward from a screen edge.
  const BUTTON_GAP = 12; // gap between button edge and tray edge
  const HALF_BTN = 22;   // ~half the like button's height
  const TAIL_INSET = 14; // keep the tail this far from the rounded corners
  let layout = $derived.by(() => {
    const vw = typeof window !== 'undefined' ? window.innerWidth : 9999;
    const vh = typeof window !== 'undefined' ? window.innerHeight : 9999;

    // Horizontal: centre the tray on the button, clamped into the viewport.
    let left = originX - trayWidth / 2;
    left = Math.min(Math.max(left, EDGE_MARGIN), vw - EDGE_MARGIN - trayWidth);

    // Vertical: decide above vs below by which side actually has room for
    // the whole tray. Prefer above when it fits; else below; else (a very
    // small viewport) pick the side with more space. Then clamp so it
    // never runs off the top or bottom.
    const aboveTop = originY - HALF_BTN - BUTTON_GAP - trayHeight;
    const belowTop = originY + HALF_BTN + BUTTON_GAP;
    const fitsAbove = aboveTop >= EDGE_MARGIN;
    const fitsBelow = belowTop + trayHeight <= vh - EDGE_MARGIN;
    let placeBelow;
    if (fitsAbove) placeBelow = false;
    else if (fitsBelow) placeBelow = true;
    else placeBelow = (vh - originY) > originY;

    const top = placeBelow
      ? Math.min(belowTop, vh - EDGE_MARGIN - trayHeight)
      : Math.max(aboveTop, EDGE_MARGIN);

    // Tail x: exactly the button centre relative to the tray's left edge,
    // only pulled in if it would land on a rounded corner.
    const tailX = Math.min(
      Math.max(originX - left, TAIL_INSET),
      trayWidth - TAIL_INSET,
    );

    return { left, top, tailX, placeBelow };
  });

  // Which cell the finger is over — lets the existing press-drag-release
  // flow highlight and commit without lifting. Pure geometry against the
  // rendered cell rects; robust and grid-simple.
  let cellCenters = $derived.by(() => {
    const { left, top } = layout;
    const originYTop = top + PAD;
    const originXLeft = left + PAD;
    return reactions.map((r, i) => {
      const col = i % 7;
      const row = Math.floor(i / 7);
      return {
        ...r,
        cx: originXLeft + col * (cellSize + GAP) + cellSize / 2,
        cy: originYTop + row * (cellSize + GAP) + cellSize / 2,
      };
    });
  });

  let activeIdx = $derived.by(() => {
    if (cellCenters.length === 0) return -1;
    // Finger still on/near the button (hasn't moved up into the tray) —
    // no highlight yet, so a plain long-press just opens the tray.
    if (Math.hypot(touchX - originX, touchY - originY) < 24) return -1;
    let best = -1;
    let bestDist = Infinity;
    for (let i = 0; i < cellCenters.length; i++) {
      const d = Math.hypot(touchX - cellCenters[i].cx, touchY - cellCenters[i].cy);
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    // Only highlight if the finger is actually within the tray band.
    return bestDist <= cellSize * 1.1 ? best : -1;
  });

  $effect(() => {
    highlightedType = activeIdx >= 0 ? cellCenters[activeIdx].type : null;
  });

  // Mild haptic as the highlighted cell changes. No-ops on iOS Safari.
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

<div
  class="tray-overlay"
  class:tray-overlay-armed={armed}
  use:portal
  aria-hidden="true"
  onpointerdown={(e) => {
    if (!armed) return;
    const t = e.target as HTMLElement | null;
    // Tap on a cell → let the cell handle it (onpointerup picks). Tap on
    // the backdrop → dismiss, and stop the event so it can't reach or
    // navigate the element behind the overlay.
    if (t && t.closest && t.closest('.tray-cell')) return;
    e.preventDefault();
    e.stopPropagation();
    ondismiss?.();
  }}
>
  <div
    class="react-tray"
    style="
      left: {layout.left}px;
      top: {layout.top}px;
      --cols: {cols};
      --cell: {cellSize}px;
      --gap: {GAP}px;
      --pad: {PAD}px;
    "
  >
    {#each reactions as r, i (r.type)}
      <button
        type="button"
        class="tray-cell"
        class:tray-cell-active={i === activeIdx}
        style="animation-delay: {18 * i}ms;"
        aria-label={r.label}
        onpointerup={(e) => { e.stopPropagation(); onpick?.(r.type); }}
      >
        {#if r.image}
          <img class="cell-image" src={r.image} alt="" />
        {:else}
          <span class="cell-emoji">{r.emoji}</span>
        {/if}
      </button>
    {/each}

    <!-- Pointer tail: a rotated square hanging off the tray's bottom
         edge, its x locked to the button centre so it always aims at the
         button the tray erupted from. -->
    <span
      class="tray-tail"
      class:tray-tail-below={layout.placeBelow}
      style="left: {layout.tailX}px;"
    ></span>
  </div>
</div>

<style>
  .tray-overlay {
    position: fixed;
    inset: 0;
    z-index: 10000;
    /* The button's touch handlers are the source of truth for the
       finger position; don't let the overlay swallow the gesture. The
       cells re-enable pointer events on themselves for tap-to-pick. */
    pointer-events: none;
    user-select: none;
    -webkit-user-select: none;
    -webkit-touch-callout: none;
    /* Kill the iOS tap-highlight flash and any selection outline when the
       armed backdrop is tapped (the tap lands on the overlay, not the
       link behind it, but suppress highlight defensively). */
    -webkit-tap-highlight-color: transparent;
    touch-action: none;
  }

  /* Once armed (waiting for a tap), the backdrop catches pointer events so
     an outside tap dismisses the tray instead of passing through to the
     post/link behind it. The cells re-enable their own pointer events. */
  .tray-overlay-armed {
    pointer-events: auto;
  }

  .react-tray {
    position: absolute;
    /* Only `left`/`top` position the tray; without these, an inherited
       `right` from the full-screen overlay stretched the box and pooled
       the slack on one side (visible as extra right padding). */
    right: auto;
    bottom: auto;
    box-sizing: border-box;
    width: max-content;
    display: grid;
    grid-template-columns: repeat(var(--cols), var(--cell));
    gap: var(--gap);
    padding: var(--pad);
    /* Tinted, translucent surface that echoes the feed wash without
       matching it — a frosted panel that reads clearly over any post. */
    background: color-mix(in oklab, var(--color-bg-wash, #f4f1fd) 82%, var(--color-surface-container-lowest));
    background: color-mix(
      in oklab,
      var(--color-bg-wash, #f4f1fd) 70%,
      color-mix(in oklab, var(--color-primary, #6c3edd) 8%, var(--color-surface-container-lowest))
    );
    border: 1px solid color-mix(in oklab, var(--color-primary, #6c3edd) 14%, transparent);
    border-radius: 24px;
    box-shadow:
      0 12px 34px color-mix(in oklab, var(--color-primary, #6c3edd) 22%, transparent),
      0 3px 10px rgba(0, 0, 0, 0.10);
    backdrop-filter: blur(14px) saturate(1.25);
    -webkit-backdrop-filter: blur(14px) saturate(1.25);
    transform-origin: bottom center;
    animation: tray-pop 200ms cubic-bezier(0.2, 0.9, 0.3, 1.25);
  }

  @keyframes tray-pop {
    from {
      opacity: 0;
      transform: scale(0.82) translateY(8px);
    }
    to {
      opacity: 1;
      transform: none;
    }
  }

  .tray-cell {
    pointer-events: auto;
    width: var(--cell);
    height: var(--cell);
    display: flex;
    align-items: center;
    justify-content: center;
    border: none;
    padding: 0;
    background: none;
    border-radius: 14px;
    cursor: pointer;
    transform: scale(0);
    animation: cell-in 260ms cubic-bezier(0.2, 0.9, 0.3, 1.4) forwards;
    transition:
      transform 120ms ease,
      background 120ms ease;
  }

  @keyframes cell-in {
    to {
      transform: scale(1);
    }
  }

  .tray-cell:hover,
  .tray-cell-active {
    background: color-mix(in oklab, var(--color-primary, #6c3edd) 16%, transparent);
    transform: scale(1.18);
  }

  .cell-emoji {
    font-size: calc(var(--cell) * 0.62);
    line-height: 1;
  }

  .cell-image {
    width: calc(var(--cell) * 0.62);
    height: calc(var(--cell) * 0.62);
    object-fit: contain;
  }

  .tray-tail {
    position: absolute;
    /* Sit the beak just below the tray's bottom edge. The rotated square
       is 18px, so half its diagonal (~13px) shows below; pushing it down
       by ~7px keeps only the lower triangle visible and stops its upper
       corner poking up behind the bottom-row cells (the seam that showed
       over the first emoji). It sits BEHIND the tray (z-index:-1) so the
       tray body cleanly covers the beak's top edge. */
    top: 100%;
    width: 18px;
    height: 18px;
    margin-left: -9px;
    transform: translateY(-11px) rotate(45deg);
    z-index: -1;
    /* Same tinted surface as the tray so the beak is seamless. */
    background: color-mix(
      in oklab,
      var(--color-bg-wash, #f4f1fd) 70%,
      color-mix(in oklab, var(--color-primary, #6c3edd) 8%, var(--color-surface-container-lowest))
    );
    border-right: 1px solid color-mix(in oklab, var(--color-primary, #6c3edd) 14%, transparent);
    border-bottom: 1px solid color-mix(in oklab, var(--color-primary, #6c3edd) 14%, transparent);
    border-bottom-right-radius: 4px;
    box-shadow: 2px 4px 7px color-mix(in oklab, var(--color-primary, #6c3edd) 12%, transparent);
  }

  /* When the tray sits below the button, the beak points UP from the
     tray's top edge instead. */
  .tray-tail-below {
    top: auto;
    bottom: 100%;
    transform: translateY(11px) rotate(45deg);
    border-right: none;
    border-bottom: none;
    border-left: 1px solid color-mix(in oklab, var(--color-primary, #6c3edd) 14%, transparent);
    border-top: 1px solid color-mix(in oklab, var(--color-primary, #6c3edd) 14%, transparent);
    border-bottom-right-radius: 0;
    border-top-left-radius: 4px;
    box-shadow: -2px -4px 7px color-mix(in oklab, var(--color-primary, #6c3edd) 12%, transparent);
  }

  @media (prefers-reduced-motion: reduce) {
    .react-tray,
    .tray-cell {
      animation: none;
      transform: none;
    }
    .tray-cell {
      transform: scale(1);
    }
  }
</style>
