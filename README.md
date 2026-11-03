# 从零到集群：Vue + Python 前后端分离实战教程

> 一套**能跑起来、能亲眼看见效果**的系统性教程。
> 主题：前后端分离 → 集群部署 → Session 集中式管理 → MySQL / Redis 集群。
> 技术栈：Vue 3 + Vite / Python FastAPI / Redis / MySQL 8 / Nginx / Docker Compose。

---

## 0. 这套教程解决什么问题

很多人学「前后端分离」时，能写出登录页面，也能调通接口，但一遇到下面这些问题就卡住：

- 本地跑得好好的，一上服务器就跨域报错；
- 部署了两个后端，用户登录后刷新一下突然变成「未登录」；
- 听说要用 Redis 存 Session，但不知道为什么，也不知道代码该怎么写；
- 听说 MySQL 要做主从、读写分离，但不知道在集群里到底谁写谁读；
- 「负载均衡」「无状态」「水平扩容」这些词都认识，连起来就懵。

这套教程用**一个完整的、可以直接运行的留言板 + 登录系统**，把这些概念全部串起来，并且设计了 3 个「肉眼可见」的实验，让你不是背概念，而是**亲手把问题复现出来，再亲手修好**。

### 适合谁

- 写过一点前端或后端，但没做过完整部署的人；
- 想从「单机开发」进阶到「生产级架构」的人；
- 不需要提前懂 Docker，命令都给全了，复制粘贴即可。

### 学完你能做到

1. 说清楚浏览器、Nginx、Vue、Python、Redis、MySQL 之间每一次请求怎么走；
2. 从零写出 Cookie + Redis 的集中式 Session 登录；
3. 用 Docker Compose 在一台电脑上起一个 3 副本后端 + MySQL 主从 + Redis 的集群；
4. 解释并复现「本地 Session 在集群下失效」这个经典 bug；
5. 知道下一步该学什么（HTTPS、CI/CD、K8s、消息队列…）。

---

## 1. 先建立一个「世界观」：用一家餐厅讲完整个架构

抽象概念最难记，我们先统一一套比喻，后面所有章节都用它。

| 架构里的东西 | 餐厅里的角色 | 它干什么 |
| --- | --- | --- |
| 浏览器 | 顾客 | 看菜单、点菜、坐着等上菜 |
| Vue 前端（静态页面） | 菜单 + 服务员的话术本 | 只负责「长什么样、怎么问」，不负责做菜 |
| Nginx 反向代理 / 负载均衡 | 门口的**叫号机 + 领班** | 顾客只认这一个门；领班决定这单交给哪个后厨，也负责把菜单（静态页面）递给顾客 |
| Python 后端（多个副本） | **好几个一模一样的后厨** | 真正处理业务：验身份、算数据、下单 |
| Redis | 后厨墙上的**共享小黑板** | 谁当班都能看、都能改。上面写着「3 号桌是 VIP，已点 2 个菜」 |
| MySQL 主库 | **总账本（只此一本，负责写）** | 所有正式记录写在这里 |
| MySQL 从库 | 总账本的**复印本（只读）** | 有人要查账就查复印件，别去翻总账本，省得堵住收银台 |

### 关键的一句话

> 顾客（浏览器）从来不直接跟后厨（Python）说话，也不知道有几个后厨。
> 它只跟领班（Nginx）说话；领班把活派给任意一个后厨；
> 而后厨们之所以能无缝接手任何一单，是因为**谁都不把顾客信息记在自己兜里，全写在共享小黑板（Redis）上**。

这句话就是「前后端分离 + 集群 + Session 集中式管理」的全部核心。后面所有代码都在实现它。

---

## 2. 学习路线（建议按顺序走）

```
第 1 步  跑起来          → 5 分钟看到登录页面能用（先用单机版）
第 2 步  前后端分离      → 搞懂「谁渲染页面」「为什么有跨域」「两种部署姿势」
第 3 步  Session        → 先故意写错（内存 Session），亲眼看到集群下掉登录
第 4 步  Redis 集中式   → 改成 Redis，再刷新 100 次都不掉登录
第 5 步  负载均衡       → 看请求被轮流打到 3 个后端副本
第 6 步  MySQL 主从     → 写走主库、读走从库，并在管理页看到证据
第 7 步  完整集群       → docker compose 一键起全套，理解每一条配置
第 8 步  上线           → 腾讯云部署（docs/08）：密钥外置、HTTPS、一键发布、自动回滚
```

对应文档：

| 章节 | 文件 | 解决什么疑问 |
| --- | --- | --- |
| 01 | [`docs/01-前后端分离与跨域.md`](docs/01-前后端分离与跨域.md) | 为什么要分离？CORS 到底是什么？开发和生产为什么不一样？ |
| 02 | [`docs/02-Session集中式管理.md`](docs/02-Session集中式管理.md) | Cookie / Session / Token / JWT 都是啥？为什么集群必须用 Redis？ |
| 03 | [`docs/03-集群与负载均衡.md`](docs/03-集群与负载均衡.md) | 什么叫「无状态」？副本怎么扩？Nginx 怎么分流？粘性会话要不要？ |
| 04 | [`docs/04-MySQL主从与读写分离.md`](docs/04-MySQL主从与读写分离.md) | binlog/GTID 是什么？主从怎么同步？代码里怎么读写分离？ |
| 05 | [`docs/05-Redis详解.md`](docs/05-Redis详解.md) | Redis 为什么快？持久化、过期、哨兵、Cluster 分别解决什么？ |
| 06 | [`docs/06-部署实战与验证.md`](docs/06-部署实战与验证.md) | 每条命令干什么？3 个必做实验怎么操作？怎么验证？ |
| 07 | [`docs/07-常见坑与进阶.md`](docs/07-常见坑与进阶.md) | 上传文件、定时任务、WebSocket、缓存一致性、下一步学什么 |
| 08 | [`docs/08-腾讯云自动化部署.md`](docs/08-腾讯云自动化部署.md) | 怎么选服务器？怎么把密码赶出代码？HTTPS 怎么办？一条命令怎么部署、回滚、备份？ |

---

## 3. 整体架构拓扑

### 3.1 开发环境（你写代码的电脑）

```
  浏览器 http://localhost:5173
        │
        ▼
  Vite 开发服务器 (Node)
   ├── /            → 返回 Vue 页面（热更新）
   └── /api/*       → proxy 转发到 http://localhost:8000   ← 关键：骗过浏览器，变成「同源」
                            │
                            ▼
                     FastAPI (uvicorn --reload)  ← 单副本
                       ├── Redis (localhost:6379)   存 Session
                       └── SQLite / MySQL            存业务数据
```

开发时用 **Vite 代理**，生产时用 **Nginx 反向代理**，两者目的完全一样：**让浏览器只看到一个域名，从而不存在跨域**。这是全教程最重要的工程直觉。

### 3.2 生产 / 集群环境（本项目 Docker Compose 起的就是这个）

```
                          浏览器
                             │  只访问 http://localhost:8080
                             ▼
              ┌──────────────────────────────┐
              │  Nginx (lb)  反向代理 + 负载均衡 │
              │  /      → 前端静态资源容器        │
              │  /api/  → upstream backend_pool │
              └───────────┬──────────────────┘
                          │ 轮询 round-robin
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
  ┌──────────┐     ┌──────────┐     ┌──────────┐
  │backend-1 │     │backend-2 │     │backend-3 │   ← 完全相同、互不认识
  │ FastAPI  │     │ FastAPI  │     │ FastAPI  │      谁都不存用户状态
  └────┬─────┘     └────┬─────┘     └────┬─────┘
       │                │                │
       └────────────────┼────────────────┘
                        │
        ┌───────────────┴───────────────┐
        ▼                               ▼
  ┌───────────┐                  ┌──────────────┐
  │  Redis    │  sess:*         │ MySQL 主库     │ ← 写 (INSERT/UPDATE/DELETE)
  │ 共享 Session│                 └──────┬───────┘
  └───────────┘                        │ binlog / GTID 自动同步
                                       ▼
                                ┌──────────────┐
                                │ MySQL 从库     │ ← 读 (SELECT)
                                └──────────────┘
```

三个要点：

1. **浏览器只有一个入口**（Nginx），所以前端代码里 `axios` 直接请求 `/api/xxx`，不写死任何 IP 或端口；
2. **后端是无状态的**：任何一个副本挂了、被换掉，都不影响用户登录态，因为状态在 Redis；
3. **数据库读写分开**：写主库，主库通过 binlog 把变更同步给从库；查询走从库。

---

## 4. 5 分钟跑起来（两种方式，任选其一）

> 环境要求：Docker Desktop（Windows 上装好并启动）即可。
> 想不用 Docker 本地跑，看 [4.2](#42-本地开发模式不用-docker-跑后端)。

### 4.1 方式 A：单机最小版（强烈建议第一步先跑这个）

```powershell
cd i:/work-body-dir/fullstack-cluster-tutorial
docker compose -f deploy/docker-compose.simple.yml up -d --build
```

等 30~60 秒，浏览器打开 **<http://localhost:8080>**，用 `alice / 123456` 登录。

这一版包含：1 个 Nginx + 1 个前端 + 1 个后端 + 1 个 MySQL + 1 个 Redis。
目的是让你**先看到一个能用的系统**，而不是一上来被 8 个容器劝退。

```powershell
# 看日志
docker compose -f deploy/docker-compose.simple.yml logs -f backend
# 关掉
docker compose -f deploy/docker-compose.simple.yml down
```

### 4.2 方式 B：完整集群版（第 7 步再跑）

```powershell
docker compose -f deploy/docker-compose.yml up -d --build
```

同样访问 **<http://localhost:8080>**。这一版会起：

| 容器 | 数量 | 作用 |
| --- | --- | --- |
| `lb` | 1 | Nginx 负载均衡 + 统一入口 |
| `frontend` | 1 | Vue 编译后的静态资源 |
| `backend-1/2/3` | 3 | 三个完全相同的 FastAPI 副本 |
| `redis` | 1 | 集中式 Session（教学用单实例，生产详见 05 章） |
| `mysql-master` | 1 | 主库，只写 |
| `mysql-slave` | 1 | 从库，只读 |
| `replica-init` | 1 | 一次性容器，自动把主从复制关系配好 |

> 想看接口文档：集群版把 `backend-1` 的 8000 映射到了宿主机 **<http://localhost:8001/docs>**，
> 可以直接在网页上调接口，观察返回里的 `handled_by`、`db_role` 等证据字段。

### 4.3 本地开发模式（不用 Docker 跑后端）

想改代码看热更新，用这个：

```powershell
# ① 终端 1：只借用 Docker 起一个 Redis 和一个 MySQL（也可以用 SQLite，见 .env）
docker run -d --name demo-redis -p 6379:6379 redis:7-alpine

# ② 终端 2：后端
cd i:/work-body-dir/fullstack-cluster-tutorial/backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
uvicorn app.main:app --reload --port 8000

# ③ 终端 3：前端
cd i:/work-body-dir/fullstack-cluster-tutorial/frontend
npm install
npm run dev
```

打开 **<http://localhost:5173>**。后端接口文档（FastAPI 自带）在 **<http://localhost:8000/docs>**，可以直接在网页上调接口，非常方便学习。

> `.env` 里 `DB_WRITE_URL=sqlite:///./demo.db` 时连 MySQL 都不用装，适合只想快速理解 Session 的同学。
> 想连真 MySQL 就改成 `mysql+pymysql://demo:demo123@localhost:3306/fullstack_demo`。

---

## 5. 三个必做实验（本教程的精华）

### 实验 1：亲手制造「集群掉登录」bug

```powershell
# 用「内存 Session」启动集群（故意的错误写法）
$env:SESSION_BACKEND = "memory"
docker compose -f deploy/docker-compose.yml up -d --build
```

登录后**连续刷新页面 10 次**，点开首页的「本次请求由哪个副本处理」卡片。
你会看到副本 id 在 `backend-1/2/3` 之间跳，而且**大概三分之二的刷新会跳回登录页**。

原因：登录请求被打到 `backend-1`，Session 只存在 `backend-1` 的内存里；下一次请求被领班派给 `backend-2`，它不认识你。

👉 这就是「有状态服务无法水平扩容」，对应 [02 章](docs/02-Session集中式管理.md)。

### 实验 2：改成 Redis，问题消失

```powershell
Remove-Item Env:SESSION_BACKEND
docker compose -f deploy/docker-compose.yml up -d --build
```

再刷新 100 次：副本依旧在变，**但登录态稳如泰山**，而且「会话访问计数」会持续累加（3 个副本改的是同一份 Redis 数据）。

在「架构实验室」页面还能直接看到 Redis 里那条 `sess:xxx` 的原始内容和剩余过期时间 —— Session 不再是黑盒。

### 实验 3：验证负载均衡与读写分离

- 首页「实例信息」卡片每刷新一次就换一个 `instance_id` → 轮询生效；
- 新建一条留言，然后看 `docs/06` 里的命令查主库/从库的 binlog 与数据 → 主从同步生效；
- 留言板页的「读取」标签会显示这次查询走的是 `replica` 还是 `primary`（从库不可用时自动降级到主库，这叫**故障降级**）。

完整操作步骤见 [`docs/06-部署实战与验证.md`](docs/06-部署实战与验证.md)。

---

## 6. 项目目录速查

```
fullstack-cluster-tutorial/
├── README.md                      ← 你正在看的：总纲 + 快速开始
├── docs/                          ← 8 篇通俗详解文档
├── backend/                       ← Python FastAPI 后端
│   ├── app/
│   │   ├── config.py              ← 所有配置（环境变量 → 两种运行模式）
│   │   ├── session_store.py       ← ★ 核心：内存 Session vs Redis Session 对照实现
│   │   ├── database.py            ← ★ 核心：主库写 / 从库读 + 启动锁 + 故障降级
│   │   ├── models.py              ← User / Note 表
│   │   ├── deps.py                ← ★ 核心：从 Cookie 取 sid → 查 Redis → 得到当前用户
│   │   ├── main.py                ← 应用装配、CORS、启动初始化
│   │   └── routers/
│   │       ├── auth.py            ← 登录 / 登出 / 当前用户 / Session 透视
│   │       ├── notes.py           ← 留言 CRUD（演示读写分离）
│   │       └── system.py          ← 实例信息、健康检查、架构探针
│   ├── requirements.txt
│   ├── Dockerfile
│   └── .env.example
├── frontend/                      ← Vue 3 + Vite
│   ├── vite.config.js             ← ★ 开发代理 /api → 8000
│   ├── src/
│   │   ├── api/index.js           ← ★ axios 全局配置（withCredentials、拦截器）
│   │   ├── router/index.js        ← 路由守卫（未登录跳转）
│   │   ├── stores/user.js         ← Pinia 用户状态
│   │   ├── views/LoginView.vue
│   │   ├── views/HomeView.vue     ← 留言板 + 实例信息
│   │   └── views/LabView.vue      ← ★ 架构实验室：Session 内容、路由证据
│   ├── Dockerfile                 ← 多阶段构建：npm build → nginx 托管
│   └── nginx.conf
├── deploy/
│   ├── docker-compose.simple.yml  ← 第 1 步：单机最小可运行
│   ├── docker-compose.yml         ← 第 7 步：完整集群
│   ├── nginx-lb.conf              ← ★ upstream + 反向代理规则（集群版）
│   ├── nginx-lb-simple.conf       ← 单机版的同源转发配置
│   ├── mysql/master.cnf, slave.cnf, init/*.sql
│   ├── redis/redis.conf
│   └── cloud/                     ← ★ 生产部署：HTTPS、密钥外置、数据库不暴露端口
└── scripts/
    ├── verify-cluster.ps1         ← 一键验证脚本（自动打 12 次请求看副本分布）
    ├── reset.ps1                  ← 清空重来
    └── cloud/                     ← ★ init-server / deploy / backup / rollback / publish
```

**带 ★ 的文件是最值得逐行读的**，所有抽象概念都落在这些文件里。

---

## 7. 核心概念速查表（先混个脸熟，后面章节会展开）

| 概念 | 一句话解释 | 本项目里的位置 |
| --- | --- | --- |
| 前后端分离 | 前端只管界面，后端只给 JSON 数据，两边靠 HTTP 接口约定合作 | `frontend/src/api/` ↔ `backend/app/routers/` |
| 同源策略 / CORS | 浏览器默认禁止 A 域名读 B 域名的数据；服务端要显式「放行」 | `main.py` 的 `CORSMiddleware` |
| 反向代理 | 服务端替浏览器去请求别人，浏览器以为只有一个域名 | `deploy/nginx-lb.conf` |
| 负载均衡 | 把请求按规则分给多个相同的后端 | `upstream backend_pool` |
| 无状态 | 后端自己不存用户数据，谁来接请求都一样 | `session_store.py` 的 Redis 实现 |
| Cookie / Session | Cookie 是浏览器替你保管的一张「号码牌」；Session 是服务器上凭号码牌查到的那份档案 | `deps.py` + Redis `sess:*` |
| Session 集中式 | 所有后端共用一处（Redis）存档案 | `SESSION_BACKEND=redis` |
| JWT / Token | 把档案直接加密写进号码牌里，服务端不用查库（另一种路线） | 02 章对比讲解 |
| 水平扩容 | 不够就多开几个一模一样的后端副本 | `backend-1/2/3` |
| 主从复制 | 主库把每次改动记成 binlog，从库照着重放 | `deploy/mysql/` |
| 读写分离 | 写找主库，读找从库 | `database.py` 的 `write_engine` / `read_engine` |
| 缓存 / 过期 | Redis 给每个 key 设 TTL，到期自动删，天然适合 Session | `SESSION_TTL_SECONDS` |

---

## 8. 一条请求到底怎么走（把它背下来，架构就通了）

以「登录后刷新首页」为例：

1. 浏览器访问 `http://localhost:8080/`，Nginx 把 `/` 代理给 `frontend` 容器，返回 `index.html` + JS；
2. Vue 挂载，`router` 守卫不知道你登没登录，于是 `axios.get('/api/auth/me')`；
3. 浏览器自动带上 Cookie `session_id=abc...`（`HttpOnly`，JS 读不到，防 XSS 偷号）；
4. 请求到 `http://localhost:8080/api/auth/me` —— **还是同一个域名，没有跨域**；
5. Nginx 匹配 `location /api/`，按轮询转给 `backend-2`（这次轮到它）；
6. `backend-2` 的 `get_current_user()` 从 Cookie 取出 `abc...`，去 Redis 查 `sess:abc...`；
7. 查到了 → 拿到 `user_id=1, username=alice`，顺便把 `hits` 加 1 写回 Redis；
8. 需要留言列表 → 用 `read_engine` 查 MySQL **从库**；
9. 组装 JSON 返回，Vue 渲染出「欢迎 alice」和留言列表；
10. 首页还显示：`本次由 backend-2 处理` —— 下次刷新可能就是 `backend-3`，但用户毫无感知。

**整个过程中，`backend-2` 本地没有任何关于 alice 的持久数据。** 这就是集群能随便加减副本的底气。

---

## 9. 常见问题

**Q：一定要 Docker 吗？**
A：不是必须。4.3 的本地模式只要 Python + Node + 一个 Redis 就行，MySQL 还能先用 SQLite 顶上。但「集群」这个概念不用 Docker 很难在一台机器上演示，所以集群部分强烈建议用。

**Q：为什么不用 Flask / Django？**
A：FastAPI 自带交互式接口文档 `/docs`，对学习最友好，异步支持和类型提示也是现代 Python 后端的主流。概念（路由、中间件、依赖注入、ORM）在 Flask/Django 里完全通用。

**Q：为什么不用 JWT 而要讲 Cookie + Redis Session？**
A：因为你要学的是「**集中式 Session 管理**」，JWT 恰好是「去中心化」的另一条路。02 章会把两条路摆在一起对比，你会更清楚什么时候该选哪个。

**Q：一主一从、单 Redis 也叫集群吗？**
A：这是**最小可复现的教学集群**，把「多副本 + 共享状态 + 主从分离」三个核心机制都跑通了。生产级高可用（Redis 哨兵/Cluster、MySQL MGR、多 Nginx + Keepalived）在 05 / 07 章给出升级路线。

**Q：Windows 上命令不一样吗？**
A：本教程命令全部按 **PowerShell** 写。Linux/macOS 用户把 `Copy-Item` 换成 `cp`、`$env:X = "y"` 换成 `export X=y` 即可，其余完全一致。

---

## 10. 开始吧

1. 先跑 [4.1 单机最小版](#41-方式-a单机最小版强烈建议第一步先跑这个)，把系统用起来；
2. 读 [`docs/01-前后端分离与跨域.md`](docs/01-前后端分离与跨域.md)，边读边对照 `frontend/src/api/index.js` 和 `backend/app/main.py`；
3. 做实验 1 和实验 2，这是全教程最值钱的 10 分钟；
4. 再按 02 → 07 章顺序推进。

> 学习建议：每读完一章，就去改一行代码、刷新一次页面看看变化。
> 架构不是看懂的，是**把 bug 复现出来再修掉**才真正懂的。
