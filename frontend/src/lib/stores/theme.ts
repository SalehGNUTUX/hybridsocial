import { writable } from 'svelte/store';
import type { ThemeConfig } from '$lib/api/types.js';
import { browser } from '$app/environment';

export const themeStore = writable<ThemeConfig | null>(null);

// Maps admin theme keys → the CSS custom properties the app actually
// reads. A single key can write to several properties when the app
// uses multiple aliases (e.g. color_primary_contrast flows into both
// --color-on-primary and --color-text-on-primary).
const PROPERTY_MAP: Record<string, string[]> = {
  color_primary: ['--color-primary'],
  color_primary_hover: ['--color-primary-hover'],
  color_primary_soft: ['--color-primary-soft'],
  color_primary_contrast: ['--color-on-primary', '--color-text-on-primary'],
  color_secondary: ['--color-secondary'],
  color_accent: ['--color-accent'],
  color_success: ['--color-success'],
  color_warning: ['--color-warning'],
  color_danger: ['--color-danger', '--color-error'],
  color_info: ['--color-info'],
  color_bg: ['--color-bg', '--color-background'],
  color_bg_wash: ['--color-bg-wash'],
  color_surface: ['--color-surface'],
  color_border: ['--color-border'],
  color_text: ['--color-text'],
  color_text_secondary: ['--color-text-secondary'],
  color_text_link: ['--color-text-link'],
  gradient_start: ['--gradient-start'],
  gradient_end: ['--gradient-end'],
  gradient_direction: ['--gradient-direction'],
  font_family: ['--font-sans'],
};

// border_radius (sharp/rounded/pill) and density (compact/comfortable/
// spacious) are discrete choices, not colors — applied as data
// attributes so the app's CSS can key off them if it wants.
const ATTR_KEYS: Array<keyof ThemeConfig> = ['border_radius', 'density'];

// Parse a #rgb / #rrggbb string into "r, g, b" channels for use inside
// rgba(var(--color-primary-rgb), <alpha>). Returns null for anything
// that isn't a valid hex colour so we leave the CSS default in place.
function hexToRgbChannels(hex: string): string | null {
  const m = /^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.exec(hex.trim());
  if (!m) return null;
  let h = m[1];
  if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return `${r}, ${g}, ${b}`;
}

export function applyTheme(config: ThemeConfig | null): void {
  themeStore.set(config);
  if (!browser || !config) return;

  const root = document.documentElement;

  for (const [key, cssVars] of Object.entries(PROPERTY_MAP)) {
    const value = (config as Record<string, unknown>)[key];
    if (typeof value === 'string' && value !== '') {
      for (const v of cssVars) root.style.setProperty(v, value);
    }
  }

  // Keep --color-primary-rgb (used for rgba() tints/focus rings) in sync
  // with the brand colour so alpha-composited accents match the override
  // instead of falling back to the CSS default.
  if (typeof config.color_primary === 'string' && config.color_primary !== '') {
    const channels = hexToRgbChannels(config.color_primary);
    if (channels) root.style.setProperty('--color-primary-rgb', channels);
  }

  for (const key of ATTR_KEYS) {
    const value = (config as Record<string, unknown>)[key as string];
    if (typeof value === 'string' && value !== '') {
      root.setAttribute(`data-${(key as string).replace('_', '-')}`, value);
    }
  }
}

export function clearTheme(): void {
  themeStore.set(null);
  if (!browser) return;

  const root = document.documentElement;
  for (const cssVars of Object.values(PROPERTY_MAP)) {
    for (const v of cssVars) root.style.removeProperty(v);
  }
  root.style.removeProperty('--color-primary-rgb');
  for (const key of ATTR_KEYS) {
    root.removeAttribute(`data-${(key as string).replace('_', '-')}`);
  }
}
