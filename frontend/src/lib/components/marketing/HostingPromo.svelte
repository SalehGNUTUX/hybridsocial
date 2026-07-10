<script lang="ts">
  // Managed hosting CTA — shown on the About page for everyone (logged-in
  // and anonymous). Also used in the anonymous legal sidebar.
  let {
    variant = 'card',
    href = 'https://hybridsocial.io/hosting',
    headline = 'Launch your own server',
    subhead = 'Get a fully managed instance. We handle the infrastructure, updates, and security — you focus on building your community.',
  }: {
    variant?: 'card' | 'inline';
    href?: string;
    headline?: string;
    subhead?: string;
  } = $props();
</script>

<aside class="hosting-promo hosting-promo-{variant}" aria-label="Managed hosting promotion">
  <div class="hosting-badge">Managed hosting</div>

  <h3 class="hosting-headline">{headline}</h3>

  <p class="hosting-sub">{subhead}</p>

  <ul class="hosting-features">
    <li>
      <svg class="check" viewBox="0 0 24 24" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>
      Your own domain &amp; branding
    </li>
    <li>
      <svg class="check" viewBox="0 0 24 24" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>
      Automatic updates &amp; backups
    </li>
    <li>
      <svg class="check" viewBox="0 0 24 24" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>
      Full federation support
    </li>
    <li>
      <svg class="check" viewBox="0 0 24 24" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>
      Priority support
    </li>
  </ul>

  <a class="hosting-cta" {href} target="_blank" rel="noopener">
    Get started
    <span aria-hidden="true" class="cta-arrow">→</span>
  </a>

  <p class="hosting-footnote">Plans start at $9/month</p>
</aside>

<style>
  .hosting-promo {
    --promo-accent: var(--color-primary);
    display: block;
    background: linear-gradient(180deg, var(--color-primary-soft, #e8fbf7) 0%, var(--color-surface-raised, #ffffff) 100%);
    border: 1px solid var(--color-primary-soft, #cbeee6);
    border-radius: var(--radius-xl);
    padding: var(--space-5);
    transition: transform 0.3s ease, box-shadow 0.3s ease;
  }

  .hosting-promo-card {
    max-width: 100%;
  }

  .hosting-promo-inline {
    margin-block-start: var(--space-8);
  }

  .hosting-promo:hover {
    transform: translateY(-2px);
    box-shadow: 0 4px 16px rgba(108, 62, 221, 0.1);
  }

  .hosting-badge {
    display: inline-block;
    font-size: 0.65rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--promo-accent);
    background: var(--color-primary-soft, rgba(108, 62, 221, 0.1));
    padding: 2px 8px;
    border-radius: var(--radius-full);
    margin-block-end: var(--space-3);
  }

  .hosting-headline {
    font-size: var(--text-lg);
    font-weight: 700;
    color: var(--color-text);
    margin: 0 0 var(--space-2) 0;
  }

  .hosting-sub {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    line-height: 1.5;
    margin: 0 0 var(--space-4) 0;
  }

  .hosting-features {
    list-style: none;
    padding: 0;
    margin: 0 0 var(--space-5) 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .hosting-features li {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--text-sm);
    color: var(--color-text);
  }

  .check {
    width: 16px;
    height: 16px;
    fill: none;
    stroke: var(--promo-accent);
    stroke-width: 2.5;
    stroke-linecap: round;
    stroke-linejoin: round;
    flex-shrink: 0;
  }

  .hosting-cta {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-3) var(--space-5);
    background: var(--promo-accent);
    color: var(--color-text-on-primary);
    border-radius: var(--radius-lg);
    font-size: var(--text-sm);
    font-weight: 700;
    text-decoration: none;
    transition: background var(--transition-fast), transform 0.15s ease;
  }

  .hosting-cta:hover {
    background: var(--color-primary-hover);
    text-decoration: none;
  }

  .hosting-cta:active {
    transform: scale(0.97);
  }

  .cta-arrow {
    transition: transform 0.2s ease;
  }

  .hosting-cta:hover .cta-arrow {
    transform: translateX(3px);
  }

  .hosting-footnote {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
    margin: var(--space-3) 0 0 0;
  }

  @media (prefers-reduced-motion: reduce) {
    .hosting-promo,
    .cta-arrow {
      transition: none;
    }

    .hosting-promo:hover {
      transform: none;
    }
  }
</style>
