<script setup>
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import api from '../api'
import { useUserStore } from '../stores/user'

const store = useUserStore()
const router = useRouter()

const info = ref(null)
const rawSession = ref(null)
const samples = ref([])
const running = ref(false)
const notice = ref('')

const distribution = computed(() => {
  const map = {}
  for (const name of samples.value) map[name] = (map[name] || 0) + 1
  return Object.entries(map).sort((a, b) => b[1] - a[1])
})

async function load() {
  try {
    const [sessionDetail, sysInfo] = await Promise.all([
      api.get('/auth/session'),
      api.get('/system/info'),
    ])
    rawSession.value = sessionDetail
    info.value = sysInfo
  } catch (e) {
    notice.value = '读取失败：' + (e.response?.data?.detail || e.message)
  }
}

/**
 * 连打 N 次探针，记录每次是哪个副本处理的。
 * 这就是「负载均衡在轮询」最直接的证据。
 */
async function sample(n = 9) {
  running.value = true
  samples.value = []
  notice.value = ''
  try {
    for (let i = 0; i < n; i += 1) {
      const r = await api.get('/system/info')
      samples.value.push(r.instance_id)
    }
    notice.value = `已连续请求 ${n} 次，命中 ${distribution.value.length} 个副本。注意：登录状态始终没变。`
  } catch (e) {
    notice.value = '请求失败：' + (e.response?.data?.detail || e.message)
  } finally {
    running.value = false
  }
}

/**
 * 模拟管理员踢人：删掉服务端的会话档案。
 * 因为档案是集中存的，删一次 → 全集群立刻都不认这张号码牌。
 */
async function kickMe() {
  try {
    await api.post('/auth/logout')
    notice.value = '服务端会话已删除。现在任何副本都查不到你的档案 → 全集群立即失效。'
    store.user = null
    setTimeout(() => router.replace('/login'), 1200)
  } catch (e) {
    notice.value = '操作失败：' + (e.response?.data?.detail || e.message)
  }
}

onMounted(load)
</script>

<template>
  <div>
    <div class="lab-head">
      <div>
        <h2>架构实验室</h2>
        <p class="hint">
          把「看不见的架构」变成「看得见的数字」。每个卡片都对应后端的一个真实接口。
        </p>
      </div>
      <div class="row">
        <button class="btn btn-ghost" @click="load">刷新数据</button>
        <button class="btn btn-primary" :disabled="running" @click="sample(9)">
          {{ running ? '请求中…' : '连打 9 次看副本分布' }}
        </button>
      </div>
    </div>

    <div v-if="notice" class="alert alert-info">{{ notice }}</div>

    <div class="stat-grid">
      <div class="card stat">
        <div class="stat-label">当前副本</div>
        <div class="stat-value">{{ info?.instance_id || '—' }}</div>
        <div class="stat-hint">/api/system/info → instance_id</div>
      </div>
      <div class="card stat">
        <div class="stat-label">Session 后端</div>
        <div class="stat-value" :class="info?.session_backend === 'redis' ? 'ok' : 'warn'">
          {{ info?.session_backend || '—' }}
        </div>
        <div class="stat-hint">环境变量 SESSION_BACKEND</div>
      </div>
      <div class="card stat">
        <div class="stat-label">会话访问次数</div>
        <div class="stat-value">{{ rawSession?.value?.hits ?? '—' }}</div>
        <div class="stat-hint">多个副本共同累加同一个计数</div>
      </div>
      <div class="card stat">
        <div class="stat-label">全局请求计数</div>
        <div class="stat-value">{{ info?.global_request_count ?? '—' }}</div>
        <div class="stat-hint">Redis INCR stats:requests</div>
      </div>
    </div>

    <div class="grid-2">
      <div class="stack">
        <!-- 副本分布 -->
        <section class="card">
          <div class="card-title">
            <span>负载均衡证据</span>
            <small>最近 {{ samples.length }} 次请求落在哪个副本</small>
          </div>

          <div v-if="!distribution.length" class="empty">
            点上面的「连打 9 次看副本分布」，观察请求如何在 3 个副本间轮转。
          </div>

          <div v-else class="bars">
            <div v-for="[name, count] in distribution" :key="name" class="bar-row">
              <span class="bar-name mono">{{ name }}</span>
              <div class="bar-track">
                <div class="bar-fill" :style="{ width: (count / samples.length) * 100 + '%' }"></div>
              </div>
              <span class="bar-count mono">{{ count }} 次</span>
            </div>
            <p class="hint">
              默认轮询（round-robin）：1 → 2 → 3 → 1…。若某个副本被停掉，Nginx 会在
              <code>max_fails</code> 次失败后自动摘除它。
            </p>
          </div>

          <div v-if="samples.length" class="sequence mono">
            <span v-for="(s, i) in samples" :key="i" class="seq-item" :title="`第 ${i + 1} 次请求`">
              {{ s.replace('backend-', '') }}
            </span>
          </div>
        </section>

        <!-- Session 原文 -->
        <section class="card">
          <div class="card-title">
            <span>服务端 Session 档案原文</span>
            <small>GET /api/auth/session</small>
          </div>
          <pre class="code">{{ JSON.stringify(rawSession, null, 2) }}</pre>
          <p class="hint">
            Cookie 里只有一个随机串（号码牌），真正的用户信息在这里。
            <code>ttl_seconds</code> 每次访问都会被重置回 1800 —— 这叫滑动过期。
          </p>
        </section>
      </div>

      <div class="stack">
        <section class="card">
          <div class="card-title">
            <span>系统探针</span>
            <small>GET /api/system/info</small>
          </div>
          <pre class="code">{{ JSON.stringify(info, null, 2) }}</pre>
        </section>

        <section class="card">
          <div class="card-title"><span>危险操作（教学用）</span></div>
          <p class="hint" style="margin-top: 0">
            删掉服务端的会话档案，模拟「管理员强制下线」。
            因为档案集中存在 Redis，删除后<b>所有副本</b>立刻都不再认识这张号码牌。
          </p>
          <button class="btn btn-danger" @click="kickMe">删除我的服务端会话</button>
          <p class="hint" style="margin-top: 12px">
            等价的命令行操作：
          </p>
          <pre class="code" style="max-height: 90px">docker compose -f deploy/docker-compose.yml exec redis \
  redis-cli -a redispass DEL sess:&lt;你的sid&gt;</pre>
        </section>

        <section class="card">
          <div class="card-title"><span>一条请求的完整旅程</span></div>
          <ol class="steps">
            <li>浏览器请求 <code>/api/auth/me</code>，自动带上 Cookie。</li>
            <li>Nginx 匹配 <code>location /api/</code>，轮询给某个副本。</li>
            <li>副本从 Cookie 取 <code>session_id</code>。</li>
            <li>拿它去 Redis 查 <code>sess:&lt;sid&gt;</code>，命中则拿到 user_id。</li>
            <li>hits +1 写回 Redis（所以计数跨副本连续）。</li>
            <li>需要留言时用 <code>read_engine</code> 查 MySQL 从库。</li>
            <li>返回 JSON，Vue 渲染。</li>
          </ol>
        </section>
      </div>
    </div>
  </div>
</template>

<style scoped>
.lab-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-end;
  gap: 16px;
  margin-bottom: 20px;
  flex-wrap: wrap;
}

.lab-head h2 {
  margin: 0 0 4px;
  font-size: 22px;
  letter-spacing: -0.4px;
}

.stack {
  display: grid;
  gap: 16px;
}

.bars {
  display: grid;
  gap: 10px;
}

.bar-row {
  display: grid;
  grid-template-columns: 92px 1fr 54px;
  align-items: center;
  gap: 10px;
  font-size: 12.5px;
}

.bar-name {
  color: #9fb2d4;
}

.bar-track {
  height: 9px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.06);
  overflow: hidden;
}

.bar-fill {
  height: 100%;
  border-radius: 999px;
  background: linear-gradient(90deg, var(--mint), var(--blue));
  transition: width 0.4s ease;
}

.bar-count {
  text-align: right;
  color: var(--muted);
}

.sequence {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  margin-top: 16px;
}

.seq-item {
  width: 26px;
  height: 26px;
  display: grid;
  place-items: center;
  border-radius: 8px;
  font-size: 12px;
  background: rgba(96, 165, 250, 0.12);
  border: 1px solid rgba(96, 165, 250, 0.28);
  color: #93c5fd;
}

.empty {
  color: var(--muted);
  font-size: 13px;
  padding: 12px 0;
}

.steps {
  margin: 0;
  padding-left: 18px;
  color: #aebbd4;
  font-size: 12.5px;
  display: grid;
  gap: 7px;
}

.steps code {
  color: #9ae6d7;
  background: rgba(94, 234, 212, 0.09);
  padding: 1px 5px;
  border-radius: 5px;
}

.ok {
  color: var(--mint);
}
.warn {
  color: var(--amber);
}

pre.code {
  white-space: pre-wrap;
  word-break: break-word;
}
</style>
