# 02 · Session 集中式管理：为什么一上集群，登录就开始「随机失效」

> 对应代码：`backend/app/session_store.py`、`backend/app/deps.py`、`backend/app/routers/auth.py`

这是整套教程**最核心**的一章。请先做 README 里的「实验 1」，带着那个诡异现象来读。

---

## 2.1 起点：HTTP 是「金鱼记忆」

HTTP 协议本身**无状态**：服务器处理完一次请求就忘了你是谁。

```
第 1 次请求：  你好，我是 alice，密码 123456   →  验过了，欢迎
第 2 次请求：  给我我的留言列表                →  你是谁？？
```

要「记住登录」，就得在多次请求之间携带某种凭证。于是有了下面这一堆名词，先别背，看它们的关系：

```
浏览器                                      服务器
┌────────────────┐                        ┌──────────────────────────┐
│ Cookie          │  ── 每次自动带上 ──▶   │ 凭 session_id 查档案       │
│ session_id=abc  │                       │  sess:abc → {user_id:1...}│
└────────────────┘  ◀── Set-Cookie ─────  │  存放位置：内存/Redis/DB   │
                                          └──────────────────────────┘
   「号码牌」                                    「档案」= Session
```

| 名词 | 到底是什么 | 一句话 |
| --- | --- | --- |
| **Cookie** | 浏览器的一小块键值存储，请求时自动带上 | 一种**传输机制**，不是数据本身 |
| **Session（会话）** | 服务端为某个用户保存的一段状态数据 | 一份**档案** |
| **session_id** | 档案的编号，通常是一个随机字符串 | 一张**号码牌** |
| **Token** | 泛称，任何「凭证」都叫 token | 宽泛概念 |
| **JWT** | 把用户信息+签名直接编码进凭证本身 | 另一种**不需要查档案**的路线 |

> 最常见的误解：「Session 存在 Cookie 里」。
> 不对。Cookie 里只存**号码牌**，档案在服务端。把档案塞进 Cookie 那叫「Cookie Session」或 JWT 思路，是另一套方案。

---

## 2.2 单机时代：Session 存哪儿都行

只有一台后端时，最简单的写法是把档案放在**进程内存**里：

```python
# 单机可用，集群必炸 —— 本项目 session_store.py 里的 MemorySessionStore
SESSIONS = {}                       # {"abc": {"user_id": 1, "username": "alice"}}

def login(username):
    sid = secrets.token_urlsafe(32)
    SESSIONS[sid] = {"username": username, "hits": 0}
    return sid

def who_am_i(sid):
    return SESSIONS.get(sid)        # 只有本进程能查到
```

单机跑得好好的：快、零依赖、重启就丢（也能接受）。

其他存法：

| 存法 | 优点 | 缺点 |
| --- | --- | --- |
| 进程内存 | 最快、最简单 | 重启丢失；**多进程/多机不共享** |
| 本地文件 | 重启不丢 | 磁盘 IO 慢；多机依然不共享；NFS 共享会锁竞争 |
| 数据库 | 可靠、持久 | 每次请求都查库，数据库压力大 |
| **Redis** | 内存级快、可设过期、天然共享、支持集群 | 多一个组件要维护 ← 生产首选 |

---

## 2.3 集群一上，灾难发生了（请务必复现）

现在把后端扩成 3 个副本，Nginx 默认**轮询**分发：

```
① POST /api/auth/login  → Nginx → backend-1
   backend-1 在自己内存里写：SESSIONS["abc"] = alice
   返回 Set-Cookie: session_id=abc                     ✅ 登录成功

② GET /api/auth/me      → Nginx → backend-2   （轮询换人了！）
   Cookie 带着 abc，但 backend-2 的 SESSIONS 里没有 abc
   → 401 未登录                                       ❌ 页面跳回登录

③ 再刷新一次            → backend-1                ✅ 又登录了
④ 再刷新一次            → backend-3                ❌ 又掉了
```

**现象：登录状态随机闪烁，大约 1/3 概率正常。** 用户会以为网站闹鬼，运维会以为负载均衡配错了。

根因一句话：**后端是「有状态」的** —— 每台机器各自记了一份用户档案，请求必须每次都落到同一台才不出错。

复现命令：

```powershell
cd i:/work-body-dir/fullstack-cluster-tutorial
$env:SESSION_BACKEND = "memory"
docker compose -f deploy/docker-compose.yml up -d --build
```

打开 <http://localhost:8080>，登录 `alice / 123456`，然后连续刷新首页，盯着「本次请求由哪个副本处理」卡片。

---

## 2.4 三条修复路线（面试常考，务必理解区别）

| 方案 | 做法 | 优点 | 致命缺点 | 用不用 |
| --- | --- | --- | --- | --- |
| **① Session 复制** | 每台后端登录时把档案广播给所有副本 | 每台本地查，快 | 副本越多广播越爆炸；扩容要同步全量；一致性难保证 | ❌ 基本淘汰（早期 Tomcat 集群用过） |
| **② 粘性会话 Sticky Session** | Nginx 用 `ip_hash` 或 Cookie 把同一用户**固定**派给同一台 | 改动最小，不用 Redis | 该副本一挂，所有绑在上面的用户集体掉线；扩容/发布时抖动；流量可能不均 | ⚠️ 临时过渡、或 WebSocket 场景 |
| **③ 集中式存储** | 所有副本都不存档案，统一去 Redis 查 | 副本完全对等、随便加减、挂一台无感、可主动踢人、可设过期 | 多一个 Redis 要保障可用性 | ✅ **生产标准答案** |

> 「前后端分离 + 集群 + Session 集中式管理」这三者是一套组合拳：
> 前后端分离让后端变成纯数据服务 → 后端无状态化 → 才能水平扩容 → 而状态必须有地方去 → Redis。

**注意**：粘性会话不是「错」，它解决的是另一类问题（比如 WebSocket 长连接、本地上传的临时文件）。但把它当成登录态的方案，等于把「高可用」又丢了。

---

## 2.5 集中式方案完整流程（逐行对照本项目代码）

### 第 1 步：登录，写 Redis，发号码牌

`backend/app/routers/auth.py`：

```python
@router.post("/login")
def login(payload: LoginIn, response: Response, request: Request, db: Session = Depends(get_write_db)):
    user = authenticate(db, payload.username, payload.password)
    if not user:
        raise HTTPException(401, "用户名或密码错误")

    sid = store.create({                       # ← 写 Redis
        "user_id": user.id,
        "username": user.username,
        "login_at": datetime.now().isoformat(),
        "login_ip": client_ip(request),
        "hits": 0,
    })

    response.set_cookie(                       # ← 只把号码牌给浏览器
        key="session_id", value=sid,
        httponly=True, samesite="lax",
        secure=settings.COOKIE_SECURE,
        max_age=settings.SESSION_TTL_SECONDS,
        path="/",
    )
    return {"ok": True, "user": {...}, "session_id_prefix": sid[:8]}
```

`backend/app/session_store.py` 里 Redis 版本的关键两行：

```python
def create(self, data: dict, ttl: int) -> str:
    sid = secrets.token_urlsafe(32)                    # 32 字节随机，猜不出来
    self.redis.setex(f"sess:{sid}", ttl, json.dumps(data))
    return sid                                         # 返回号码牌
```

Redis 里实际长这样（可在「架构实验室」页面直接看到）：

```
Key   : sess:K8sdf7Q...xyz
Value : {"user_id":1,"username":"alice","login_at":"2026-11-03T10:12:00",
         "login_ip":"172.18.0.1","hits":7}
TTL   : 1743 秒（剩余）
```

### 第 2 步：每次请求，凭号码牌查档案

`backend/app/deps.py`（全项目最该逐行读的文件）：

```python
def get_current_user(request: Request) -> dict:
    sid = request.cookies.get("session_id")       # ① 从 Cookie 取号码牌
    if not sid:
        raise HTTPException(401, "未登录")

    data = store.get(sid)                          # ② 去 Redis 查 sess:{sid}
    if not data:
        raise HTTPException(401, "登录已过期")

    store.touch(sid)                               # ③ 续期（滑动过期）
    data["hits"] = data.get("hits", 0) + 1
    store.save(sid, data)                          # ④ 写回共享档案
    return data
```

注意第 ④ 步：`hits` 是**所有副本共改同一份数据**。你在页面上刷新，副本 id 在 `1/2/3` 之间跳，但计数持续 +1 不会重置 —— 这就是「集中式」最直观的证据。

### 第 3 步：登出，删档案 + 清号码牌

```python
@router.post("/logout")
def logout(request: Request, response: Response):
    sid = request.cookies.get("session_id")
    if sid:
        store.delete(sid)                          # Redis 删掉，其它副本立刻也查不到了
    response.delete_cookie("session_id", path="/")
    return {"ok": True}
```

因为是集中存储，**一次删除，全集群立即生效**。反过来，内存 Session 方案里你在 `backend-1` 登出，`backend-2` 那份档案还活着 —— 这是一个真实的安全隐患。

---

## 2.6 设计细节（这些才是工程经验）

### Key 怎么命名

```
sess:{sid}                 会话档案，带 TTL
sess:user:{user_id}:sids   可选：某用户所有会话号，用于「踢掉其它设备」
```

加前缀便于 `SCAN`、`keyspace notification` 监控、以及和缓存 key 区分开。别直接把裸 sid 当 key。

### 过期策略：滑动续期

- 创建时 `SETEX key 1800 ...`（固定 30 分钟）；
- 每次有效访问 `EXPIRE key 1800` 重置 → **用户一直在用就一直不过期，闲置 30 分钟自动掉线**；
- Cookie 的 `Max-Age` 也要同步，否则会出现「Redis 里还在但浏览器不发了」的错位。本项目两者都刷新。

> 也可以做「绝对过期」：档案里记 `login_at`，超过 8 小时强制重新登录，防止会话被无限续期。金融类系统常这么做。

### 为什么不把用户对象直接塞 Redis

档案里存**最小必要信息**（`user_id`、用户名、登录时间）。权限、昵称等变化应该以数据库为准，否则改了权限要清理所有会话。真要缓存权限，就设短 TTL 或主动失效。

### 安全清单

| 风险 | 对策 | 本项目 |
| --- | --- | --- |
| 会话号被猜到 | `secrets.token_urlsafe(32)`，不要用自增 id / 时间戳 | ✅ |
| 会话固定攻击 (Session Fixation) | 登录成功后**重新生成** sid，别复用登录前的 | ✅ 登录时新建 |
| XSS 偷 Cookie | `HttpOnly` + `Secure` + CSP | ✅ |
| CSRF 冒用 Cookie | `SameSite=Lax`；敏感操作加 CSRF Token / 二次校验 | ✅ Lax，07 章展开 |
| 会话劫持 | 可选：把 UA / IP 段记进档案做校验；HTTPS 必开 | 记录了 `login_ip` 供对照 |
| Redis 被攻破 | 不把密码写进档案；Redis 不暴露公网、设密码 | compose 里有 `requirepass` 说明 |
| 登出后仍有效 | 删 Redis key，而不是只清浏览器 Cookie | ✅ |

### 一个很实用的能力：主动踢人

集中式之后，管理后台要「让某用户所有设备重新登录」变得极其简单：删掉该用户对应的所有 `sess:*` key 即可。JWT 路线想做这件事就得引入黑名单，反而绕回集中存储了 —— 这是选型时的重要权衡。

---

## 2.7 那 JWT 呢？两条路线对比

JWT 的思路是：**不存档案**，把用户信息直接写进凭证并签名：

```
Header.Payload.Signature
eyJhbGciOi... .eyJ1c2VyX2lkIjoxLCJleHAiOjE3... .SflKxwRJSMe...
```

服务端拿到后验签 + 看 `exp`，不需要查 Redis。

| 维度 | Cookie + Redis Session（本方案） | JWT |
| --- | --- | --- |
| 服务端是否存状态 | 存（但集中在 Redis） | 不存 |
| 每次请求开销 | 一次 Redis 查询（~0.1ms） | 一次签名校验（CPU） |
| 立即失效 / 踢人 | ✅ 删 key 即可 | ❌ 难，要么等过期，要么加黑名单（又变回集中式） |
| 改权限即时生效 | ✅ | ❌ 旧 token 里还是旧权限 |
| 跨域 / 多端 | 依赖 Cookie，跨域要额外配置 | ✅ 放 `Authorization` 头，天然适合 App / 微服务 |
| 凭证体积 | 几十字节号码牌 | 几百字节，信息越多越大 |
| 泄露后果 | 号码牌本身无信息，可立刻作废 | Payload 可解码（别放敏感信息），作废困难 |
| 典型场景 | **传统 Web 站点、管理后台、需要强管控的系统** | 微服务间调用、移动端、第三方开放 API、一次性邮箱链接 |

**选型建议**：

- 做**网站 / 后台管理系统**，尤其需要「踢下线、强制改密后全员重登、权限即时生效」→ 用集中式 Session（本方案）；
- 做**开放 API / 多端 / 服务间无状态调用** → JWT 更合适；
- 大厂常见做法是**混合**：浏览器侧用 Cookie + Redis Session，内部服务之间用 JWT/mTLS。

> 有个常见误区：「用了 JWT 就是无状态、就比 Session 高级」。
> 实际上只要你需要「立即失效」，最终还是得有个共享存储。架构没有银弹，只看需求。

---

## 2.8 本项目特意留的「教学开关」

`backend/app/session_store.py` 实现了同一个接口的两套存储：

```python
# backend/app/config.py
SESSION_BACKEND = os.getenv("SESSION_BACKEND", "redis")   # redis | memory
```

```python
# 工厂：一个开关切换「错误示范」和「正确示范」
if settings.SESSION_BACKEND == "memory":
    store = MemorySessionStore()      # 进程内字典 → 集群下会掉登录
else:
    store = RedisSessionStore(...)    # 共享小黑板 → 集群下稳如泰山
```

上层 `deps.py`、`routers/auth.py` **完全不用改**。这正是好架构的样子：把「状态放哪儿」这个决策收敛到一个地方，业务代码不关心。

建议你做这个练习：先只用 `MemorySessionStore` 跑通单机，理解接口；再切 Redis 跑集群，理解差别；最后自己加第三种实现 `DatabaseSessionStore`（用 MySQL 存 Session），体会「可替换的存储层」。

---

## 2.9 小结与动手任务

- HTTP 无状态 → 需要 Cookie（号码牌）+ Session（档案）；
- 集群下档案不能放在任何单台后端内存里，否则登录随机失效；
- **集中式 Redis Session** 是标准答案：副本无状态、可任意扩缩、可即时踢人、天然过期；
- 粘性会话是权宜之计，Session 复制已淘汰；
- JWT 是另一条路线，牺牲「即时失效」换「完全无状态」，按场景选。

**动手任务**

1. 用 `$env:SESSION_BACKEND="memory"` 复现掉登录，记录 10 次刷新中成功几次、分别命中哪个副本；
2. 切回 `redis`，刷新 20 次，观察「会话访问计数」是否单调 +1；
3. 在「架构实验室」页点「查看 Session 原文」，对照 2.5 的 key/value/TTL；
4. 登录后执行 `docker compose -f deploy/docker-compose.yml exec redis redis-cli -a redispass`，手动 `GET sess:<sid>`、`TTL sess:<sid>`，再 `DEL` 掉它，刷新页面 —— 你会被立刻踢下线（这就是「主动失效」的威力）；
5. 思考题：如果把 `SESSION_TTL_SECONDS` 改成 `10`，一直刷新页面会不会掉线？为什么？（答案：滑动续期）

> 下一章：[03 · 集群与负载均衡](03-集群与负载均衡.md) —— 领班是怎么派单的，以及集群还带来了哪些新麻烦。
