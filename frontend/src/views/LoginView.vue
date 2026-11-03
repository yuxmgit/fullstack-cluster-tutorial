<script setup>
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useUserStore } from '../stores/user'

const store = useUserStore()
const router = useRouter()
const route = useRoute()

const username = ref('alice')
const password = ref('123456')
const loading = ref(false)
const error = ref('')

function fill(name) {
  username.value = name
  password.value = '123456'
}

async function submit() {
  error.value = ''
  if (!username.value.trim()) {
    error.value = '请输入用户名'
    return
  }
  loading.value = true
  try {
    await store.login(username.value.trim(), password.value)
    router.replace(route.query.redirect || '/')
  } catch (e) {
    error.value =
      e.response?.data?.detail ||
      '登录失败：请确认后端已启动（本地开发 http://localhost:8000）'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="login-wrap">
    <section class="login-hero">
      <span class="chip chip-mint">Vue 3 + FastAPI + Redis + MySQL</span>
      <h1>
        一次登录，<br />
        <span class="grad">三个副本都认识你</span>
      </h1>
      <p class="hero-text">
        这是一个可以亲手做实验的教学项目。你会看到请求在
        <code>backend-1 / 2 / 3</code> 之间轮转，而登录状态始终不丢——
        因为用户档案不在任何一台机器里，而在 Redis。
      </p>

      <ul class="hero-points">
        <li><b>前后端分离</b><span>Nginx 同源，浏览器零跨域</span></li>
        <li><b>集中式 Session</b><span>Cookie 只带号码牌，档案在 Redis</span></li>
        <li><b>MySQL 主从</b><span>写主库、读从库，从库挂了自动降级</span></li>
      </ul>

      <div class="flow mono">
        <span>浏览器</span><i>→</i><span>Nginx</span><i>→</i>
        <span class="hl">backend-N</span><i>→</i><span class="hl2">Redis</span>
        <i>/</i><span class="hl3">MySQL</span>
      </div>
    </section>

    <section class="card login-card">
      <h2>登录</h2>
      <p class="muted" style="margin-top: -6px; margin-bottom: 18px; font-size: 12.5px">
        演示账号：alice / 123456 &nbsp;·&nbsp; bob / 123456
      </p>

      <div v-if="error" class="alert alert-error">{{ error }}</div>

      <form @submit.prevent="submit">
        <div class="field">
          <label for="username">用户名</label>
          <input id="username" v-model="username" autocomplete="username" placeholder="alice" />
        </div>
        <div class="field">
          <label for="password">密码</label>
          <input
            id="password"
            v-model="password"
            type="password"
            autocomplete="current-password"
            placeholder="123456"
          />
        </div>

        <button class="btn btn-primary login-btn" type="submit" :disabled="loading">
          {{ loading ? '正在登录…' : '登录' }}
        </button>
      </form>

      <div class="quick">
        <span class="muted">快速填充：</span>
        <button class="btn btn-ghost btn-sm" type="button" @click="fill('alice')">alice</button>
        <button class="btn btn-ghost btn-sm" type="button" @click="fill('bob')">bob</button>
      </div>

      <p class="login-note">
        登录成功后，浏览器会收到一个 <code>HttpOnly</code> 的
        <code>session_id</code> Cookie。<br />
        按 F12 → Application → Cookies 就能看到它。
      </p>
    </section>
  </div>
</template>

<style scoped>
.login-wrap {
  display: grid;
  grid-template-columns: 1.1fr 0.9fr;
  gap: 46px;
  align-items: center;
  padding: 40px 0 20px;
}

.login-hero h1 {
  font-size: 42px;
  line-height: 1.22;
  letter-spacing: -1px;
  margin: 18px 0 16px;
}

.grad {
  background: linear-gradient(120deg, var(--mint), var(--blue) 55%, var(--violet));
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
}

.hero-text {
  color: var(--muted);
  font-size: 14.5px;
  max-width: 460px;
}

.hero-text code {
  color: #9ae6d7;
  background: rgba(94, 234, 212, 0.09);
  padding: 1px 5px;
  border-radius: 5px;
}

.hero-points {
  list-style: none;
  padding: 0;
  margin: 26px 0;
  display: grid;
  gap: 12px;
}

.hero-points li {
  display: flex;
  gap: 12px;
  align-items: baseline;
  font-size: 13.5px;
}

.hero-points b {
  color: #d7f7ef;
  min-width: 104px;
  font-weight: 600;
}

.hero-points span {
  color: var(--muted);
}

.flow {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  padding: 10px 14px;
  border: 1px dashed rgba(255, 255, 255, 0.14);
  border-radius: 12px;
  font-size: 12px;
  color: var(--muted);
}

.flow i {
  font-style: normal;
  color: #3f4f6d;
}

.flow .hl {
  color: var(--blue);
}

.flow .hl2 {
  color: var(--mint);
}

.flow .hl3 {
  color: var(--violet);
}

.login-card {
  padding: 28px 26px;
  box-shadow: var(--shadow);
}

.login-card h2 {
  margin: 0;
  font-size: 20px;
}

.login-btn {
  width: 100%;
  padding: 12px;
  margin-top: 4px;
  font-size: 14.5px;
}

.quick {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 16px;
  font-size: 12.5px;
}

.login-note {
  margin: 18px 0 0;
  font-size: 12px;
  color: #64748b;
  line-height: 1.75;
  border-top: 1px dashed rgba(255, 255, 255, 0.08);
  padding-top: 14px;
}

.login-note code {
  color: #9ae6d7;
}

@media (max-width: 900px) {
  .login-wrap {
    grid-template-columns: 1fr;
    gap: 28px;
    padding-top: 16px;
  }
  .login-hero h1 {
    font-size: 30px;
  }
}
</style>
