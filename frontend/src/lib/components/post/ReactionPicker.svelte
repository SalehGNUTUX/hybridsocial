<script lang="ts">
  import { onMount } from 'svelte';
  import { currentUser } from '$lib/stores/auth.js';
  import { getPremiumReactions, type PremiumReactionsResponse } from '$lib/api/conversations.js';

  let {
    selected = null,
    onselect,
  }: {
    selected?: string | null;
    onselect: (emoji: string) => void;
  } = $props();

  // The fixed 7 default reactions every user can pick. The user-asked
  // canonical set: thumbs-up Like, ❤ Love, 🤯 Wow, 🥰 Care, 😡 Angry,
  // 😢 Sad, 😂 LOL.
  const defaultReactions = [
    { emoji: '\u{1F44D}', type: 'like', label: 'Like' },
    { emoji: '\u{2764}\u{FE0F}', type: 'love', label: 'Love' },
    { emoji: '\u{1F92F}', type: 'wow', label: 'Wow' },
    { emoji: '\u{1F970}', type: 'care', label: 'Care' },
    { emoji: '\u{1F621}', type: 'angry', label: 'Angry' },
    { emoji: '\u{1F622}', type: 'sad', label: 'Sad' },
    { emoji: '\u{1F602}', type: 'lol', label: 'LOL' },
  ];

  // Premium reactions come from the admin-curated catalog
  // (/api/v1/premium_reactions). They render alongside the defaults
  // for paid tiers (custom_emoji limit) and are visually muted
  // otherwise — a small "Premium" hint replaces the click handler.
  let premium = $state<PremiumReactionsResponse['premium']>([]);
  let isPremiumUser = $derived(!!$currentUser?.limits?.custom_emoji);

  onMount(async () => {
    try {
      const cat = await getPremiumReactions();
      premium = cat.premium ?? [];
    } catch {
      premium = [];
    }
  });

  let reactions = $derived(
    [
      ...defaultReactions,
      ...premium.map((p) => ({
        emoji: p.character || ':' + p.shortcode + ':',
        type: p.shortcode,
        label: p.shortcode,
        image: p.image_url,
        premium: true,
      })),
    ] as Array<{ emoji: string; type: string; label: string; image?: string | null; premium?: boolean }>,
  );

  function handleClick(e: MouseEvent, type: string, isPremium?: boolean) {
    e.stopPropagation();
    if (isPremium && !isPremiumUser) return;
    onselect(type);
  }

  function handleKeydown(e: KeyboardEvent, type: string, isPremium?: boolean) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      e.stopPropagation();
      if (isPremium && !isPremiumUser) return;
      onselect(type);
    }
  }
</script>

<div
  class="reaction-picker"
  role="group"
  aria-label="Reactions"
  onclick={(e) => e.stopPropagation()}
>
  {#each reactions as reaction, i (reaction.type)}
    <button
      type="button"
      class="reaction-btn"
      class:reaction-selected={selected === reaction.type}
      class:reaction-locked={reaction.premium && !isPremiumUser}
      style="animation-delay: {80 + i * 40}ms"
      onclick={(e) => handleClick(e, reaction.type, reaction.premium)}
      onkeydown={(e) => handleKeydown(e, reaction.type, reaction.premium)}
      aria-label={reaction.premium && !isPremiumUser ? `${reaction.label} (premium)` : reaction.label}
      aria-pressed={selected === reaction.type}
      title={reaction.premium && !isPremiumUser ? `${reaction.label} — premium tier only` : reaction.label}
      disabled={reaction.premium && !isPremiumUser}
    >
      {#if reaction.image}
        <img class="reaction-image" src={reaction.image} alt={reaction.label} />
      {:else}
        <span class="reaction-emoji">{reaction.emoji}</span>
      {/if}
    </button>
  {/each}
</div>

<style>
  .reaction-picker {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    padding: var(--space-2);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-full);
    box-shadow: var(--shadow-lg);
    transform-origin: bottom center;
    animation: picker-unfold 0.25s cubic-bezier(0.22, 1, 0.36, 1) forwards;
  }

  @keyframes picker-unfold {
    0% {
      opacity: 0;
      transform: scaleX(0.3) scaleY(0.6);
    }
    100% {
      opacity: 1;
      transform: scaleX(1) scaleY(1);
    }
  }

  .reaction-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    background: transparent;
    border: none;
    border-radius: var(--radius-full);
    cursor: pointer;
    transition: transform 150ms cubic-bezier(0.34, 1.56, 0.64, 1), background-color 150ms ease;
    opacity: 0;
    transform: scale(0) translateY(8px);
    animation: emoji-pop 0.35s cubic-bezier(0.34, 1.56, 0.64, 1) forwards;
  }

  @keyframes emoji-pop {
    0% {
      opacity: 0;
      transform: scale(0) translateY(8px);
    }
    60% {
      opacity: 1;
      transform: scale(1.2) translateY(-2px);
    }
    100% {
      opacity: 1;
      transform: scale(1) translateY(0);
    }
  }

  .reaction-btn:hover {
    transform: scale(1.3) translateY(-4px);
    background: var(--color-bg-tertiary);
  }

  .reaction-btn:hover .reaction-emoji {
    animation: emoji-wiggle 0.5s ease;
  }

  @keyframes emoji-wiggle {
    0% { transform: rotate(0deg); }
    20% { transform: rotate(-12deg) scale(1.1); }
    40% { transform: rotate(10deg) scale(1.1); }
    60% { transform: rotate(-6deg); }
    80% { transform: rotate(4deg); }
    100% { transform: rotate(0deg); }
  }

  .reaction-btn:focus-visible {
    outline: 2px solid var(--color-primary);
    outline-offset: 1px;
  }

  .reaction-selected {
    background: var(--color-primary-light);
  }

  .reaction-selected:hover {
    background: var(--color-primary-light);
  }

  .reaction-emoji {
    font-size: 1.25rem;
    line-height: 1;
  }

  .reaction-image {
    width: 22px;
    height: 22px;
    object-fit: contain;
  }

  .reaction-locked {
    opacity: 0.45;
    filter: grayscale(0.6);
    cursor: not-allowed;
  }

  .reaction-locked:hover {
    transform: none;
    background: transparent;
  }
</style>
