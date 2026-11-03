import { defineStore } from 'pinia'
import api from '../api'

/**
 * 用户状态。
 *
 * 注意：前端保存的 user 只是「展示用的缓存」，
 * 真正的登录判定永远以服务端 /api/auth/me 为准
 * （用户可能在别的标签页登出、Session 可能过期、可能被管理员踢下线）。
 */
export const useUserStore = defineStore('user', {
  state: () => ({
    user: null,
    session: null,
    handledBy: '',
    loaded: false,
  }),

  getters: {
    isLoggedIn: (state) => !!state.user,
  },

  actions: {
    async bootstrap() {
      try {
        const data = await api.get('/auth/me')
        this.user = data.user
        this.session = data.session
        this.handledBy = data.handled_by
      } catch {
        this.user = null
        this.session = null
      } finally {
        this.loaded = true
      }
    },

    async login(username, password) {
      const data = await api.post('/auth/login', { username, password })
      this.user = data.user
      // 登录响应里没有完整 session，主动拉一次，让页面能展示会话细节
      await this.bootstrap()
      return data
    },

    async refreshMe() {
      const data = await api.get('/auth/me')
      this.user = data.user
      this.session = data.session
      this.handledBy = data.handled_by
      return data
    },

    async logout() {
      try {
        await api.post('/auth/logout')
      } finally {
        this.user = null
        this.session = null
      }
    },
  },
})
