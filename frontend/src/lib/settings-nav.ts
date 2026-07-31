// Single source of truth for the settings catalog. Consumed by the
// settings index (card grid) and the settings layout (back-bar title
// lookup) so the two never drift.

export interface SettingsItem {
  href: string;
  label: string;
  description: string;
  /** SVG path data for a 24x24 stroked icon. */
  icon: string;
}

export interface SettingsGroup {
  title: string;
  items: SettingsItem[];
}

export const settingsGroups: SettingsGroup[] = [
  {
    title: 'Account',
    items: [
      { href: '/settings/profile', label: 'Profile', description: 'Name, bio, avatar, and header image', icon: 'M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8z' },
      { href: '/settings/account', label: 'Account', description: 'Email, language, verification, and deletion', icon: 'M12 15v2m-6 4h12a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2zm10-10V7a4 4 0 0 0-8 0v4' },
    ],
  },
  {
    title: 'Preferences',
    items: [
      { href: '/settings/appearance', label: 'Appearance', description: 'Light, dark, or match your system', icon: 'M12 3a9 9 0 1 0 9 9 9 9 0 0 0-9-9zm0 0v18' },
      { href: '/settings/notifications', label: 'Notifications', description: 'Choose what you get notified about', icon: 'M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9M13.73 21a2 2 0 0 1-3.46 0' },
      { href: '/settings/privacy', label: 'Privacy', description: 'Visibility, discoverability, and messages', icon: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z' },
    ],
  },
  {
    title: 'Safety',
    items: [
      { href: '/settings/blocks', label: 'Blocked & muted', description: "Accounts and domains you've blocked, and accounts you've muted", icon: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zM4.93 4.93l14.14 14.14' },
      { href: '/settings/filters', label: 'Content Filters', description: 'Hide posts that match keywords', icon: 'M22 3H2l8 9.46V19l4 2v-8.54L22 3z' },
      { href: '/settings/follow-requests', label: 'Follow Requests', description: 'Approve or decline requests to follow you', icon: 'M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M8.5 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM17 11l2 2 4-4' },
      { href: '/settings/moderation', label: 'Moderation status', description: 'Content moderators removed, and how to appeal before it is permanently deleted', icon: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10zM9 12l2 2 4-4' },
    ],
  },
  {
    title: 'Security & access',
    items: [
      { href: '/settings/security', label: 'Security', description: 'Password, two-factor, security keys, and signed-in devices', icon: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10zM9 12l2 2 4-4' },
    ],
  },
  {
    title: 'Your data',
    items: [
      { href: '/settings/history', label: 'History', description: 'Recently viewed posts on this device', icon: 'M3 3v5h5M3.05 13a9 9 0 1 0 .5-4m-.5 4h4m5-8v5l3 2' },
      { href: '/settings/import-export', label: 'Move / back up account', description: 'Export or import your data, and move to another server', icon: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3' },
    ],
  },
  {
    title: 'More',
    items: [
      { href: '/settings/donations', label: 'Donations', description: 'Crypto wallet addresses for tips', icon: 'M12 2v20M17 5H9.5a3.5 3.5 0 000 7h5a3.5 3.5 0 010 7H6' },
      { href: '/settings/developers', label: 'Developers', description: 'API apps, bots, and access tokens', icon: 'M16 18l6-6-6-6M8 6l-6 6 6 6' },
    ],
  },
];

const byHref = new Map<string, SettingsItem>();
for (const g of settingsGroups) for (const it of g.items) byHref.set(it.href, it);

/** Resolve the settings item for a pathname (longest prefix match), or null on the index. */
export function settingsItemForPath(pathname: string): SettingsItem | null {
  if (pathname === '/settings' || pathname === '/settings/') return null;
  let best: SettingsItem | null = null;
  for (const [href, item] of byHref) {
    if (pathname === href || pathname.startsWith(href + '/')) {
      if (!best || href.length > best.href.length) best = item;
    }
  }
  return best;
}
