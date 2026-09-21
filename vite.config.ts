import { defineConfig } from 'vite';
 
export default defineConfig({
  // Some older CommonJS packages (e.g. 3d-view-controls, stats-js) reference
  // Node's `global` object. Webpack used to polyfill this automatically;
  // Vite doesn't, so we alias it to the browser's `globalThis` ourselves.
  define: {
    global: 'globalThis',
  },
  // Relative base so the built site works regardless of the repo name
  // it's published under on GitHub Pages (https://username.github.io/repo-name/).
  base: './',
  server: {
    host: '127.0.0.1',
    port: 5661,
    strictPort: true,
    open: false,
    allowedHosts: [
      'fireball.tonyxtian.com',
      'localhost',
      '127.0.0.1'
    ],
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
});
 
