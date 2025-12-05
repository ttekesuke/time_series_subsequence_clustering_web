import { defineConfig } from 'vite'
import RubyPlugin from 'vite-plugin-ruby'
import vue from '@vitejs/plugin-vue'
import vuetify from 'vite-plugin-vuetify'

export default defineConfig({
  optimizeDeps: {
    noDiscovery: true,
  },
  plugins: [
    RubyPlugin(),
    vue(),
    vuetify({ autoImport: true }),
  ],
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes('node_modules')) {
            return 'vendor' // 依存ライブラリを vendor.js に分ける
          }
        }
      }
    },
    target: 'esnext',
    minify: 'esbuild',
    chunkSizeWarningLimit: 1000,
    cssCodeSplit: true,
    sourcemap: false,
  }

})
