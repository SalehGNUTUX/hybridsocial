// Swaps `:shortcode:` text inside post HTML for an <img> element so
// federated posts that reference custom emojis (e.g. Fosstodon's
// `:blobcatgooglywanted2:`) render with the actual sticker instead
// of bare text. The server validates emoji.url as http/https and the
// shortcode regex is `[A-Za-z0-9_]+`, so direct interpolation is
// safe — but we still escape attribute values defensively in case a
// remote peer ever ships malformed data.

export interface CustomEmoji {
  shortcode: string;
  url: string;
  static_url?: string;
}

function escapeAttr(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Replace every occurrence of `:<shortcode>:` in the given HTML with
 * an inline <img> for emojis we have a manifest for. Other text is
 * untouched. Returns the original string when there's nothing to
 * substitute so callers can pass through.
 */
export function renderCustomEmojis(html: string, emojis?: CustomEmoji[]): string {
  if (!html || !emojis || emojis.length === 0) return html;

  // Build a single regex matching any of the post's shortcodes. The
  // shortcodes are alphanumeric+underscore so they survive escape
  // unchanged, but route them through escapeRegex anyway in case a
  // future shortcode policy widens the alphabet.
  const codes = emojis
    .filter((e) => e.shortcode && e.url)
    .map((e) => escapeRegex(e.shortcode))
    .join('|');
  if (!codes) return html;

  const lookup = new Map<string, CustomEmoji>();
  for (const e of emojis) lookup.set(e.shortcode, e);

  const pattern = new RegExp(`:(${codes}):`, 'g');
  return html.replace(pattern, (match, shortcode: string) => {
    const e = lookup.get(shortcode);
    if (!e) return match;
    const src = escapeAttr(e.url);
    const alt = escapeAttr(`:${shortcode}:`);
    return `<img class="custom-emoji" src="${src}" alt="${alt}" title="${alt}" loading="lazy" />`;
  });
}
