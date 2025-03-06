import { defineConfig } from 'vite'
import RubyPlugin from 'vite-plugin-ruby'
import vue from '@vitejs/plugin-vue'
import vuetify from 'vite-plugin-vuetify'

export default defineConfig({
  build: {
    minify: false, // Terserによる圧縮を無効化
    chunkSizeWarningLimit: 1024,
    rollupOptions: {
      maxParallelFileOps: 1 // ファイルの並列処理を制限
    }
  },
  plugins: [
    RubyPlugin(),
    vue(),
    vuetify({ autoImport: true }),
  ],
})
