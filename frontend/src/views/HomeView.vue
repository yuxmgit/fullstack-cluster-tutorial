<script setup>
import { computed, onMounted, ref } from 'vue'
import api from '../api'
import { useUserStore } from '../stores/user'

const store = useUserStore()

const info = ref(null)
const notes = ref([])
const dbRole = ref('')
const loading = ref(false)
const notice = ref('')

const title = ref('')
const content = ref('')
const submitting = ref(false)

const sessionBackendLabel = computed(() => {
  if (!info.value) return '—'
  return info.value.session_backend === 'redis' ? 'Redis（集中式）' : '内存（单机示范）'
})

const roleLabel = computed(() => {
  const map = {
    replica: 'MySQL 从库（只读）',
    primary: 'MySQL 主库（读写）',
    'primary(fallback)': '主库兜底（从库不可用）',
  }
  return map[dbRole.value] || dbRole.value || '—'
})

async function refresh() {
  loading.value = true
  notice.value = ''
  try {
    const [sysInfo, list, me] = await Promise.all([
      api.get('/system/info'),
      api.get('/notes'),
      api.get('/auth/me'),
    ])
    info.value = sysInfo
    notes.value = list.items
    dbRole.value = list.db_role
    store.user = me.user
    store.session = me.session
    store.handledBy = me.handled_by
  } catch (e) {
    if (e.response?.status === 401) {
      store.user = null
    } else {
      notice.value = '刷新失败：' + (e.response?.data?.detail || e.message)
    }
  } finally {
    loading.value = false
  }
}

async function createNote() {
  if (!title.value.trim()) {
    notice.value = '标题不能为空'
    return
  }
  submitting.value = true
  try {
    const res = await api.post('/notes', { title: title.value.trim(), content: content.value })
    // ★ 乐观更新：直接把手里的新对象插到列表头部。
    // 主从复制有延迟，如果立刻 GET 从库，可能读不到刚写的数据（教程 04 章）。
    notes.value = [res.note, ...notes.value]
    title.value = ''
    content.value = ''
    notice.value = `已写入 ${res.db_role}（主库），由 ${res.handled_by} 处理。列表立即显示是前端乐观更新，没有依赖从库同步。`
  } catch (e) {
    notice.value = '发布失败：' + (e.response?.data?.detail || e.message)
  } finally {
    submitting.value = false
  }
}

async function removeNote(id) {
  try {
    await api.delete(`/notes/${id}`)
    notes.value = notes.value.filter((n) => n.id !== id)
    notice.value = '已从主库删除（全局请求计数不变，说明删的是数据不是会话）'
  } catch (e) {
    notice.value = '删除失败：' + (e.response?.data?.detail || e.message)
  }
}

function fmt(ts) {
  if (!ts) return ''
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return ts
  return d.toLocaleString('zh-CN', { hour12: false })
}

onMounted(refresh)
</script>

<template>
  <div>
    <!-- 三个关键指标：副本 / Session 后端 / 全局计数 -->
    <div class="stat-grid">
      <div class="card stat">
        <div class="stat-label">本次请求由谁处理</div>
        <div class="stat-value">{{ info?.instance_id || store.handledBy || '—' }}</div>
        <div class="stat-hint">多刷新几次，它会在 3 个副本之间轮转</div>
      </div>

      <div class="card stat">
        <div class="stat-label">Session 存储</div>
        <div class="stat-value" :class="info?.session_backend === 'redis' ? 'ok' : 'warn'">
          {{ sessionBackendLabel }}
        </div>
        <div class="stat-hint">
          会话访问 {{ store.session?.hits ?? 0 }} 次 · 剩余 {{ store.session?.ttl_seconds ?? 0 }}s
        </div>
      </div>

      <div class="card stat">
        <div class="stat-label">全局请求计数</div>
        <div class="stat-value">{{ info?.global_request_count ?? '—' }}</div>
        <div class="stat-hint">存在 Redis，所有副本共享同一个数</div>
      </div>
    </div>

    <div v-if="notice" class="alert alert-info">{{ notice }}</div>

    <div class="grid-2">
      <!-- 留言板 -->
      <section class="card">
        <div class="card-title">
          <span>留言板</span>
          <span class="row">
            <span class="chip" :class="dbRole === 'replica' ? 'chip-mint' : 'chip-amber'">
              读取：{{ roleLabel }}
            </span>
            <button class="btn btn-ghost btn-sm" :disabled="loading" @click="refresh">
              {{ loading ? '刷新中…' : '刷新' }}
            </button>
          </span>
        </div>

        <form class="note-form" @submit.prevent="createNote">
          <div class="field">
            <label for="title">标题</label>
            <input id="title" v-model="title" maxlength="128" placeholder="例如：Redis 存 Session 真的更快吗？" />
          </div>
          <div class="field">
            <label for="content">内容（可选）</label>
            <textarea id="content" v-model="content" maxlength="5000" placeholder="写点什么…"></textarea>
          </div>
          <button class="btn btn-primary" type="submit" :disabled="submitting">
            {{ submitting ? '提交中…' : '发布留言（写主库）' }}
          </button>
        </form>

        <div class="note-list">
          <div v-if="!notes.length" class="empty">
            还没有留言。发布一条，然后用 <code>docker compose logs</code> 看它落到哪个副本。
          </div>

          <article v-for="n in notes" :key="n.id" class="note">
            <div class="note-head">
              <strong>{{ n.title }}</strong>
              <button class="btn btn-danger btn-sm" @click="removeNote(n.id)">删除</button>
            </div>
            <p v-if="n.content" class="note-content">{{ n.content }}</p>
            <div class="note-meta mono">
              #{{ n.id }} · {{ fmt(n.created_at) }}
            </div>
          </article>
        </div>
      </section>

      <!-- 右侧：架构说明 -->
      <aside class="side">
        <div class="card">
          <div class="card-title">
            <span>这台机器在干什么</span>
            <span class="chip chip-instance">{{ info?.instance_id || '—' }}</span>
          </div>
          <ul class="facts">
            <li>
              <span>Session 后端</span>
              <b :class="info?.session_backend === 'redis' ? 'ok' : 'warn'">
                {{ info?.session_backend || '—' }}
              </b>
            </li>
            <li><span>Redis 连通</span><b :class="info?.redis_ok ? 'ok' : 'warn'">{{ info?.redis_ok ? '是' : '否' }}</b></li>
            <li><span>读库可用</span><b :class="info?.read_replica_ok ? 'ok' : 'warn'">{{ info?.read_replica_ok ? '是' : '否（已降级）' }}</b></li>
            <li><span>写库</span><b class="mono small">{{ info?.db_write || '—' }}</b></li>
            <li><span>读库</span><b class="mono small">{{ info?.db_read || '—' }}</b></li>
            <li><span>进程存活</span><b>{{ info?.uptime_seconds ?? 0 }}s</b></li>
          </ul>
          <p class="hint" style="margin-top: 12px">{{ info?.session_backend_note }}</p>
        </div>

        <div class="card">
          <div class="card-title"><span>为什么不掉登录</span></div>
          <ol class="steps">
            <li>登录时后端在 Redis 写 <code>sess:&lt;随机串&gt;</code>，只把随机串放进 Cookie。</li>
            <li>之后每次请求，浏览器自动带上这个 Cookie。</li>
            <li>Nginx 把请求轮询给任意副本，副本拿 Cookie 里的号码牌去 <b>Redis 查同一份档案</b>。</li>
            <li>所以换副本＝换服务员，但共享小黑板还在，顾客信息不会丢。</li>
          </ol>
          <p class="hint">
            想看档案原文？去 <router-link to="/lab" class="link">架构实验室</router-link>。
          </p>
        </div>
      </aside>
    </div>
  </div>
</template>

<style scoped>
.stat-value.ok {
  color: var(--mint);
}
.stat-value.warn {
  color: var(--amber);
}

.note-form {
  padding-bottom: 18px;
  border-bottom: 1px dashed rgba(255, 255, 255, 0.08);
}

.note-list {
  margin-top: 16px;
  display: grid;
  gap: 10px;
}

.empty {
  color: var(--muted);
  font-size: 13px;
  padding: 20px 0;
  text-align: center;
}

.empty code {
  color: #9ae6d7;
}

.note {
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 12px 14px;
  background: rgba(255, 255, 255, 0.025);
}

.note-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
}

.note-head strong {
  font-size: 14px;
  font-weight: 600;
  word-break: break-word;
}

.note-content {
  margin: 6px 0 0;
  color: #b9c6dd;
  font-size: 13px;
  white-space: pre-wrap;
  word-break: break-word;
}

.note-meta {
  margin-top: 8px;
  font-size: 11px;
  color: #5b6b8c;
}

.side {
  display: grid;
  gap: 14px;
}

.facts {
  list-style: none;
  padding: 0;
  margin: 0;
  display: grid;
  gap: 9px;
  font-size: 12.5px;
}

.facts li {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  border-bottom: 1px dashed rgba(255, 255, 255, 0.05);
  padding-bottom: 7px;
}

.facts span {
  color: var(--muted);
  flex-shrink: 0;
}

.facts b {
  font-weight: 600;
  text-align: right;
  word-break: break-all;
}

.facts b.small {
  font-size: 11px;
}

.ok {
  color: var(--mint);
}
.warn {
  color: var(--amber);
}

.steps {
  margin: 0;
  padding-left: 18px;
  color: #aebbd4;
  font-size: 12.5px;
  display: grid;
  gap: 8px;
}

.steps code {
  color: #9ae6d7;
  background: rgba(94, 234, 212, 0.09);
  padding: 1px 5px;
  border-radius: 5px;
}

.link {
  color: var(--blue);
}
</style>
