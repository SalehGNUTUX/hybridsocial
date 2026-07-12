<script lang="ts">
  // Renders the instance's configured captcha. Widget providers (Cloudflare
  // Turnstile, hCaptcha) draw an inline challenge and hand back a token via
  // callback; Google reCAPTCHA v3 is invisible and executed on submit.
  //
  // Usage:
  //   <Captcha bind:this={captcha} provider={p} siteKey={k} bind:token action="register" />
  //   ...then on submit:  body.captcha_token = await captcha.getToken();
  import { onMount } from 'svelte';

  let {
    provider,
    siteKey,
    action = 'submit',
    token = $bindable(''),
  }: {
    provider: string;
    siteKey: string;
    action?: string;
    token?: string;
  } = $props();

  let container: HTMLDivElement | undefined = $state();
  let isWidget = $derived(provider === 'turnstile' || provider === 'hcaptcha');

  function scriptSrc(): string | null {
    switch (provider) {
      case 'turnstile':
        return 'https://challenges.cloudflare.com/turnstile/v0/api.js';
      case 'hcaptcha':
        return 'https://js.hcaptcha.com/1/api.js';
      case 'recaptcha':
        return `https://www.google.com/recaptcha/api.js?render=${encodeURIComponent(siteKey)}`;
      default:
        return null;
    }
  }

  function loadScript(src: string): Promise<void> {
    return new Promise((resolve, reject) => {
      if (document.querySelector(`script[data-captcha="${src}"]`)) return resolve();
      const s = document.createElement('script');
      s.src = src;
      s.async = true;
      s.defer = true;
      s.dataset.captcha = src;
      s.onload = () => resolve();
      s.onerror = () => reject(new Error('captcha script failed to load'));
      document.head.appendChild(s);
    });
  }

  type RenderApi = {
    render: (el: HTMLElement, opts: Record<string, unknown>) => string | number;
  };

  // The widget globals (window.turnstile / window.hcaptcha) appear a tick
  // after the script's onload, so poll briefly for them.
  function waitForGlobal(name: string, tries = 100): Promise<RenderApi> {
    return new Promise((resolve, reject) => {
      let n = 0;
      const iv = setInterval(() => {
        const g = (window as unknown as Record<string, RenderApi | undefined>)[name];
        if (g && typeof g.render === 'function') {
          clearInterval(iv);
          resolve(g);
        } else if (++n > tries) {
          clearInterval(iv);
          reject(new Error(`${name} did not load`));
        }
      }, 100);
    });
  }

  onMount(() => {
    if (!provider || provider === 'none' || !siteKey) return;
    const src = scriptSrc();
    if (!src) return;
    let cancelled = false;

    loadScript(src)
      .then(async () => {
        if (cancelled || !isWidget) return;
        const api = await waitForGlobal(provider);
        if (cancelled || !container) return;
        api.render(container, {
          sitekey: siteKey,
          callback: (t: string) => (token = t),
          'expired-callback': () => (token = ''),
          'error-callback': () => (token = ''),
        });
      })
      .catch(() => {
        // Leave token empty — submit gating / the server verify surfaces it.
      });

    return () => {
      cancelled = true;
    };
  });

  type GreCaptcha = {
    ready: (cb: () => void) => void;
    execute: (key: string, opts: { action: string }) => Promise<string>;
  };

  /**
   * Get a token to submit. Widget providers already hold one from their
   * callback; reCAPTCHA v3 executes a fresh, action-scoped token now.
   */
  export async function getToken(): Promise<string> {
    if (provider === 'recaptcha') {
      const gre = (window as unknown as { grecaptcha?: GreCaptcha }).grecaptcha;
      if (!gre) return '';
      await new Promise<void>((r) => gre.ready(r));
      token = await gre.execute(siteKey, { action });
      return token;
    }
    return token;
  }

  /** True when the provider draws a challenge the user must complete first. */
  export function needsInteraction(): boolean {
    return isWidget;
  }
</script>

{#if isWidget}
  <div class="captcha-widget" bind:this={container}></div>
{/if}

<style>
  .captcha-widget {
    display: flex;
    justify-content: center;
    margin-block: 8px;
    min-height: 65px;
  }
</style>
