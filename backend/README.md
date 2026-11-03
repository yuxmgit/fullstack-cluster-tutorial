# backend · FastAPI

## 本地运行（不用 Docker）

```powershell
cd i:/work-body-dir/fullstack-cluster-tutorial/backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env

# 起一个 Redis（不装 Redis 也能跑，会自动降级为内存 Session）
docker run -d --name demo-redis -p 6379:6379 redis:7-alpine

uvicorn app.main:app --reload --port 8000
```

- 接口文档（可视化调接口）：<http://localhost:8000/docs>
- 健康检查：<http://localhost:8000/api/system/health>
- 实例信息：<http://localhost:8000/api/system/info>

默认 `.env.example` 用 SQLite，零依赖即可跑通；想连 MySQL 就改 `DB_WRITE_URL` / `DB_READ_URL`。

## 关键文件

| 文件 | 作用 |
| --- | --- |
| `app/session_store.py` | ★ 内存 Session 与 Redis Session 两套实现，一个开关切换 |
| `app/deps.py` | ★ Cookie → Redis → 当前用户，认证核心三行 |
| `app/database.py` | ★ 写引擎/读引擎、从库降级、集群启动锁 |
| `app/routers/auth.py` | 登录 / 登出 / me / Session 透视 |
| `app/routers/notes.py` | 留言 CRUD，演示读写分离与越权防护 |
| `app/routers/system.py` | 实例信息、健康检查、全局计数 |

## 接口一览

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/auth/login` | 登录，返回 Set-Cookie |
| POST | `/api/auth/logout` | 登出，删除服务端会话 |
| GET | `/api/auth/me` | 当前用户 + 会话信息 + 处理副本 |
| GET | `/api/auth/session` | 教学用：Session 档案原文与 TTL |
| GET | `/api/notes` | 当前用户的留言（读从库） |
| POST | `/api/notes` | 新建留言（写主库） |
| DELETE | `/api/notes/{id}` | 删除自己的留言 |
| GET | `/api/system/health` | 进程存活探针 |
| GET | `/api/system/info` | 架构探针：副本/Redis/读写库/全局计数 |

## 环境变量

见 `.env.example`，重点是这三个：

- `SESSION_BACKEND=redis|memory` —— 集中式 / 进程内存（实验开关）
- `DB_WRITE_URL` / `DB_READ_URL` —— 主库 / 从库
- `REDIS_URL` —— 共享 Session 所在地
