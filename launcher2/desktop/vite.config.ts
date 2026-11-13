import { defineConfig } from 'vite';

export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    host: '127.0.0.1',
    watch: { ignored: ['**/src-tauri/target/**'] },
  },
  build: {
    target: 'es2022', sourcemap: false,
    rollupOptions: {
      onwarn(warning, handler) {
        if (warning.code === 'MODULE_LEVEL_DIRECTIVE' && warning.message.includes('use client')) return;
        handler(warning);
      },
    },
  },
});
