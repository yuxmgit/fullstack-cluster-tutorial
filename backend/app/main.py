"""
应用装配入口。

启动顺序（对应教程 06 章）：
    1. 等 Redis 就绪（避免容器启动顺序造成的短暂不可用）
    2. 初始化 Session 存储（redis / memory）
    3. 建表 + 插入演示账号（多副本时用 Redis 锁保证只执行一次）
"""

import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .database import init_schema_and_seed
from .routers import auth, notes, system
from .session_store import init_store, redis_ping, store_note

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s [%(name)s] %(message)s",
)
logger = logging.getLogger("app")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 1. 等 Redis（compose 的 healthcheck 已保证，这里再兜一层，最多等 30 秒）
    for attempt in range(1, 16):
        if await asyncio.to_thread(redis_ping):
            break
        logger.warning("等待 Redis 就绪 ... (%s/15)", attempt)
        await asyncio.sleep(2)

    # 2. 决定 Session 存哪儿
    store = await asyncio.to_thread(init_store)
    logger.info("Session 后端 = %s | %s", store.name, store_note())

    # 3. 建表与初始数据（集群下只由一个副本执行）
    status = await asyncio.to_thread(init_schema_and_seed)
    logger.info("数据库初始化 = %s", status)

    logger.info("实例 %s 启动完成", settings.INSTANCE_ID)
    yield
    logger.info("实例 %s 正在关闭", settings.INSTANCE_ID)


app = FastAPI(
    title="Vue + Python 前后端分离 / 集群 / 集中式 Session 教学 API",
    description="配套教程：README.md 与 docs/ 目录",
    version="1.0.0",
    lifespan=lifespan,
)

# 本地开发跨域放行；生产走 Nginx 同源时不会用到。
# 注意：带 Cookie 时 allow_origins 不能是 ["*"]，必须明确列出域名。
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router, prefix="/api/auth", tags=["认证与会话"])
app.include_router(notes.router, prefix="/api/notes", tags=["留言板（读写分离）"])
app.include_router(system.router, prefix="/api/system", tags=["系统与架构探针"])


@app.get("/", tags=["系统与架构探针"])
def root():
    return {
        "service": "fullstack-cluster-tutorial-backend",
        "instance": settings.INSTANCE_ID,
        "docs": "/docs",
        "api_prefix": "/api",
        "session_backend": settings.SESSION_BACKEND,
    }
