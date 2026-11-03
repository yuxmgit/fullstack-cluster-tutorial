// ★ 前后端分离的「唯一出口」：所有接口请求都从这里走。
import axios from 'axios'

const api = axios.create({
  // 相对路径！开发时由 Vite 代理，生产时由 Nginx 代理。
  // 绝对不要写死 http://localhost:8000，否则一进容器就全废。
  baseURL: '/api',
  timeout: 10000,
  // 允许携带 Cookie：集中式 Session 的号码牌靠它传递
  withCredentials: true,
})

// 请求拦截：可以在这里统一加 token / 请求 ID（本项目用 Cookie，无需加头）
api.interceptors.request.use((config) => config)

// 响应拦截：直接返回 data，统一处理 401
api.interceptors.response.use(
  (res) => res.data,
  (err) => {
    const url = err.config?.url || ''
    // 登录接口和启动时的探测接口返回 401 是正常业务流程，不要整页跳转
    const isAuthFlow = url.includes('/auth/login') || url.includes('/auth/me')
    if (err.response?.status === 401 && !isAuthFlow && !location.pathname.startsWith('/login')) {
      window.location.href = '/login'
    }
    return Promise.reject(err)
  }
)

export default api
