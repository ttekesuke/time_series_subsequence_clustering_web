import { defineConfig } from 'vite'
import RubyPlugin from 'vite-plugin-ruby'
import vue from '@vitejs/plugin-vue'
import vuetify from 'vite-plugin-vuetify'

export default defineConfig({
  plugins: [
    RubyPlugin(),
    vue(),
    vuetify({ autoImport: true }),
  ],
  // build: {
  //   outDir: "public/assets", // 出力ディレクトリを変更
  //   assetsDir: "", // `assets/` ではなく直下に配置する場合
  // }
})
