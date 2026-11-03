import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],

  server: {
    port: 5173,
    host: true,
    // ★ 开发环境的关键：把 /api 代理给后端。
    // 浏览器只跟 5173 打交道 → 同源 → 完全不需要 CORS。
    // 生产环境由 Nginx 做同样的事（见 deploy/nginx-lb.conf）。
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
    },
  },

  build: {
    outDir: 'dist',
    sourcemap: false,
  },
})
