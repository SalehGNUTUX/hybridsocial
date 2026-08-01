import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

const BACKEND = process.env.BACKEND_URL || 'http://localhost:4000';

export default defineConfig({
	plugins: [sveltekit()],
	build: {
		cssCodeSplit: false
	},
	server: {
		proxy: {
			'/api': { target: BACKEND, changeOrigin: true },
			// OAuth endpoints live on the backend; the consent screen at
			// /authorize is a SvelteKit route and must not be proxied.
			'/oauth': { target: BACKEND, changeOrigin: true },
			'/proxy': { target: BACKEND, changeOrigin: true },
			'/.well-known': { target: BACKEND, changeOrigin: true },
			'/actors': { target: BACKEND, changeOrigin: true },
			'/activities': { target: BACKEND, changeOrigin: true },
			'/uploads': { target: BACKEND, changeOrigin: true }
		}
	}
});
