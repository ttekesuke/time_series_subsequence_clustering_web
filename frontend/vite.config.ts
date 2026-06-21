import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import vuetify from "vite-plugin-vuetify";
import { fileURLToPath, URL } from "node:url";
import path from "path";

// このファイルのディレクトリを取得（/app/frontend になるはず）
const __dirname = fileURLToPath(new URL(".", import.meta.url));

const apiTarget = process.env.VITE_API_TARGET ?? "http://api:9111";

export default defineConfig({
  plugins: [vue(), vuetify({ autoImport: true })],
  // プロジェクトのルートをこのファイルのあるディレクトリに明示的に設定
  root: __dirname,
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
      // 絶対パスで node_modules 内のファイルを直接指定
      "opensheetmusicdisplay": path.resolve(__dirname, "node_modules/opensheetmusicdisplay/build/opensheetmusicdisplay.min.js"),
    },
  },
  define: {
    global: "window",
  },
  server: {
    host: true,
    port: 5173,
    proxy: {
      "/api": { target: apiTarget, changeOrigin: true },
    },
  },
});
