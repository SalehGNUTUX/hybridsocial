<script lang="ts">
  import AppLayout from '$lib/components/layout/AppLayout.svelte';
  import BrandMark from '$lib/components/ui/BrandMark.svelte';
  import HostingPromo from '$lib/components/marketing/HostingPromo.svelte';
  import { isLoggedIn } from '$lib/stores/auth.js';
  import { instanceName } from '$lib/stores/instance.js';

  let { children } = $props();

  // Show the full app chrome to logged-in users; the public marketing
  // chrome only for anonymous visitors. Same URL, two audiences.
  let loggedIn = $state(false);
  isLoggedIn.subscribe((v) => (loggedIn = v));
</script>

{#if loggedIn}
  <AppLayout>
    <div class="legal-in-app">
      {@render children()}
    </div>
  </AppLayout>
{:else}
<div class="public-layout">
  <header class="public-header">
    <div class="public-header-inner">
      <a href="/" class="public-logo">
        <BrandMark size={28} />
        <span>{$instanceName}</span>
      </a>
      <nav class="public-header-nav">
        <a href="/login" class="header-login-btn">Sign in</a>
      </nav>
    </div>
  </header>

  <div class="public-body">
    <main class="public-main">
      {@render children()}
    </main>

    <aside class="public-sidebar">
      <!-- Sign in card -->
      <div class="sidebar-card">
        <h3 class="sidebar-card-title">Sign in</h3>
        <p class="sidebar-card-text">Already have an account? Sign in to join the conversation.</p>
        <a href="/login" class="sidebar-btn sidebar-btn-primary">Sign in</a>
        <a href="/register" class="sidebar-btn sidebar-btn-outline">Create account</a>
      </div>

      <!-- Upsell card (shared component; also appears inline on About) -->
      <HostingPromo />


      <!-- Links card -->
      <div class="sidebar-card sidebar-card-links">
        <a href="/legal/about">About this server</a>
        <a href="/legal/privacy">Privacy Policy</a>
        <a href="/legal/terms">Terms of Service</a>
      </div>
    </aside>
  </div>

  <footer class="public-footer">
    <div class="public-footer-inner">
      <div class="footer-links">
        <a href="/legal/about">About</a>
        <a href="/legal/privacy">Privacy</a>
        <a href="/legal/terms">Terms</a>
      </div>
      <div class="footer-copy">&copy; {new Date().getFullYear()} {$instanceName}</div>
    </div>
  </footer>
</div>
{/if}

<style>
  /* Logged-in wrapper: match the max width other feed-style pages use. */
  .legal-in-app {
    max-width: var(--feed-max-width);
    margin: 0 auto;
    padding: var(--space-4);
  }

  :global(.legal-in-app .site-page) {
    max-width: none;
  }

  .public-layout {
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    background: var(--color-bg);
  }

  /* ---- Header ---- */
  .public-header {
    background: var(--color-surface-raised);
    border-block-end: 1px solid var(--color-border);
  }

  .public-header-inner {
    max-width: 1100px;
    margin: 0 auto;
    padding: var(--space-3) var(--space-6);
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .public-logo {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--text-lg);
    font-weight: 700;
    color: var(--color-text);
    text-decoration: none;
  }

  .public-header-nav {
    display: flex;
    align-items: center;
    gap: var(--space-3);
  }

  .header-login-btn {
    padding: var(--space-1) var(--space-4);
    background: var(--color-primary);
    color: var(--color-text-on-primary);
    border-radius: var(--radius-lg);
    font-size: var(--text-sm);
    font-weight: 600;
    text-decoration: none;
    transition: background var(--transition-fast);
  }

  .header-login-btn:hover {
    background: var(--color-primary-hover);
    text-decoration: none;
  }

  /* ---- Body (content + sidebar) ---- */
  .public-body {
    flex: 1;
    display: flex;
    gap: var(--space-6);
    max-width: 1100px;
    width: 100%;
    margin: 0 auto;
    padding: var(--space-8) var(--space-6);
    align-items: flex-start;
  }

  .public-main {
    flex: 1;
    min-width: 0;
    background: var(--color-surface-raised);
    border-radius: var(--radius-xl);
    border: 1px solid var(--color-border);
    padding: var(--space-8);
  }

  /* ---- Sidebar ---- */
  .public-sidebar {
    width: 300px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    position: sticky;
    top: var(--space-8);
  }

  .sidebar-card {
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl);
    padding: var(--space-5);
  }

  .sidebar-card-title {
    font-size: var(--text-base);
    font-weight: 700;
    color: var(--color-text);
    margin-block-end: var(--space-2);
  }

  .sidebar-card-text {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    line-height: 1.5;
    margin-block-end: var(--space-4);
  }

  .sidebar-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 100%;
    padding: var(--space-2) var(--space-4);
    border-radius: var(--radius-lg);
    font-size: var(--text-sm);
    font-weight: 600;
    text-decoration: none;
    transition: background var(--transition-fast), border-color var(--transition-fast);
    margin-block-end: var(--space-2);
  }

  .sidebar-btn-primary {
    background: var(--color-primary);
    color: var(--color-text-on-primary);
  }

  .sidebar-btn-primary:hover {
    background: var(--color-primary-hover);
    text-decoration: none;
  }

  .sidebar-btn-outline {
    background: transparent;
    color: var(--color-primary);
    border: 1px solid var(--color-border);
  }

  .sidebar-btn-outline:hover {
    border-color: var(--color-primary);
    background: var(--color-primary-soft);
    text-decoration: none;
  }

  /* Promo card styles moved to HostingPromo.svelte (self-contained). */

  /* ---- Links card ---- */
  .sidebar-card-links {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-4) var(--space-5);
  }

  .sidebar-card-links a {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    text-decoration: none;
  }

  .sidebar-card-links a:hover {
    color: var(--color-primary);
  }

  /* ---- Footer ---- */
  .public-footer {
    border-block-start: 1px solid var(--color-border);
    background: var(--color-surface-raised);
  }

  .public-footer-inner {
    max-width: 1100px;
    margin: 0 auto;
    padding: var(--space-5) var(--space-6);
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .footer-links {
    display: flex;
    gap: var(--space-5);
  }

  .footer-links a {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    text-decoration: none;
  }

  .footer-links a:hover {
    color: var(--color-primary);
  }

  .footer-copy {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  /* ---- Entrance animations ---- */
  @keyframes fadeUp {
    from {
      opacity: 0;
      transform: translateY(14px);
    }
    to {
      opacity: 1;
      transform: translateY(0);
    }
  }

  @keyframes fadeIn {
    from { opacity: 0; }
    to { opacity: 1; }
  }

  .public-header {
    animation: fadeIn 0.4s ease both;
  }

  .public-main {
    animation: fadeUp 0.5s cubic-bezier(0.22, 1, 0.36, 1) 0.05s both;
  }

  .public-sidebar .sidebar-card:nth-child(1) {
    animation: fadeUp 0.45s cubic-bezier(0.22, 1, 0.36, 1) 0.15s both;
  }

  .public-sidebar .sidebar-card:nth-child(2) {
    animation: fadeUp 0.45s cubic-bezier(0.22, 1, 0.36, 1) 0.25s both;
  }

  .public-sidebar .sidebar-card:nth-child(3) {
    animation: fadeUp 0.45s cubic-bezier(0.22, 1, 0.36, 1) 0.35s both;
  }

  .public-footer {
    animation: fadeIn 0.5s ease 0.3s both;
  }

  /* Subtle hover effects */
  .sidebar-card {
    transition: box-shadow 0.3s ease, transform 0.3s ease;
  }

  .sidebar-card:hover {
    box-shadow: 0 2px 12px rgba(0, 0, 0, 0.05);
  }

  .sidebar-btn {
    transition: background var(--transition-fast), border-color var(--transition-fast), transform 0.15s ease;
  }

  .sidebar-btn:active {
    transform: scale(0.985);
  }

  .header-login-btn {
    transition: background var(--transition-fast), transform 0.15s ease;
  }

  .header-login-btn:active {
    transform: scale(0.96);
  }

  @media (prefers-reduced-motion: reduce) {
    .public-header,
    .public-main,
    .sidebar-card,
    .public-footer {
      animation: none !important;
    }

    .sidebar-card:hover {
      transform: none;
    }
  }

  /* ---- Responsive ---- */
  @media (max-width: 868px) {
    .public-sidebar {
      display: none;
    }
  }

  @media (max-width: 640px) {
    .public-main {
      padding: var(--space-5);
    }

    .public-footer-inner {
      flex-direction: column;
      gap: var(--space-3);
      text-align: center;
    }
  }
</style>
