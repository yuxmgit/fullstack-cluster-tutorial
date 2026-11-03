import { createRouter, createWebHistory } from 'vue-router'
import { useUserStore } from '../stores/user'
import LoginView from '../views/LoginView.vue'
import HomeView from '../views/HomeView.vue'
import LabView from '../views/LabView.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', name: 'home', component: HomeView, meta: { requiresAuth: true } },
    { path: '/lab', name: 'lab', component: LabView, meta: { requiresAuth: true } },
    { path: '/login', name: 'login', component: LoginView },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

/**
 * 路由守卫只做「体验层」的快速拦截：
 * 如果本地已知未登录，直接跳登录页，避免闪一下空白。
 *
 * 但它不能作为安全边界 —— 真正的校验在服务端（每个接口都验 Session）。
 * 否则用户手动改前端状态就能"进"页面，虽然拿不到数据。
 */
router.beforeEach(async (to) => {
  const store = useUserStore()

  if (!store.loaded) {
    await store.bootstrap()
  }

  if (to.meta.requiresAuth && !store.isLoggedIn) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }

  if (to.name === 'login' && store.isLoggedIn) {
    return { name: 'home' }
  }

  return true
})

export default router
