<script setup>
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import { useUserStore } from './stores/user'

const store = useUserStore()
const router = useRouter()
const showNav = computed(() => store.isLoggedIn)

async function onLogout() {
  await store.logout()
  router.push('/login')
}
</script>

<template>
  <div class="app-shell">
    <header v-if="showNav" class="nav">
      <div class="nav-inner">
        <router-link to="/" class="brand">
          <span class="brand-dot"></span>
          <span>Cluster Lab</span>
        </router-link>

        <nav class="nav-links">
          <router-link to="/">留言板</router-link>
          <router-link to="/lab">架构实验室</router-link>
        </nav>

        <div class="nav-user">
          <span class="chip chip-instance" :title="'本次请求由该副本处理'">{{ store.handledBy || '—' }}</span>
          <span class="nav-name">{{ store.user?.nickname || store.user?.username }}</span>
          <button class="btn btn-ghost" @click="onLogout">退出</button>
        </div>
      </div>
    </header>

    <main class="main">
      <router-view />
    </main>

    <footer class="footer">
      Vue 3 + FastAPI + Redis 集中式 Session + MySQL 主从 · 教学示例
    </footer>
  </div>
</template>
