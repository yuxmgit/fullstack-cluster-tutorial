"""
数据库层：一个写引擎、一个读引擎。

    write_engine → 主库，负责所有 INSERT / UPDATE / DELETE
    read_engine  → 从库，负责 SELECT（从库挂了自动降级回主库）

本地开发用 SQLite 时两个 URL 相同，会自动复用同一个引擎，行为等价于单库。
"""

import logging
import time
from dataclasses import dataclass
from typing import Any, Dict, Iterator, Optional

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, declarative_base, sessionmaker

from .config import settings

logger = logging.getLogger("app.db")

Base = declarative_base()


def _make_engine(url: str) -> Engine:
    kwargs: Dict[str, Any] = {
        # 从连接池取连接前先探活，避免拿到被 MySQL 断掉的空闲连接
        "pool_pre_ping": True,
        # 连接最多活 1 小时，绕开 MySQL wait_timeout
        "pool_recycle": 3600,
        "future": True,
    }
    if url.startswith("sqlite"):
        # SQLite 默认禁止跨线程使用连接，而 FastAPI 的同步路由跑在线程池里
        kwargs["connect_args"] = {"check_same_thread": False}
    else:
        # 注意：副本数 × pool_size 才是数据库总连接数，扩容时很容易打满 max_connections
        kwargs.update(pool_size=5, max_overflow=5)

    return create_engine(url, **kwargs)


write_engine = _make_engine(settings.DB_WRITE_URL)
read_engine = write_engine if settings.same_db_for_read_write else _make_engine(settings.DB_READ_URL)

SessionLocal = sessionmaker(autoflush=False, expire_on_commit=False, future=True)


@dataclass
class DBHandle:
    """把「用的是什么库」一并返回，方便接口把证据透给前端（教学用）。"""

    session: Session
    role: str  # primary / replica / primary(fallback)


# ---------------------------------------------------------------------------
# 从库健康探测：每 10 秒最多探一次，避免每个请求都打一次
# ---------------------------------------------------------------------------
_read_state = {"checked_at": 0.0, "ok": True}
_PROBE_INTERVAL = 10.0


def read_replica_ok(force: bool = False) -> bool:
    if read_engine is write_engine:
        return True

    now = time.time()
    if not force and (now - _read_state["checked_at"]) < _PROBE_INTERVAL:
        return _read_state["ok"]

    try:
        with read_engine.connect() as conn:
            conn.exec_driver_sql("SELECT 1")
        ok = True
    except Exception as exc:  # noqa: BLE001
        logger.warning("读库不可用，本次读请求自动降级到主库：%s", exc)
        ok = False

    _read_state["checked_at"] = now
    _read_state["ok"] = ok
    return ok


def get_write_db() -> Iterator[Session]:
    """写操作依赖：所有写都进主库。"""
    db = SessionLocal(bind=write_engine)
    try:
        yield db
    finally:
        db.close()


def get_read_db() -> Iterator[DBHandle]:
    """读操作依赖：优先从库，从库不可用则降级主库（服务不中断）。"""
    if read_engine is write_engine:
        role, engine = "primary", write_engine
    elif read_replica_ok():
        role, engine = "replica", read_engine
    else:
        role, engine = "primary(fallback)", write_engine

    db = SessionLocal(bind=engine)
    try:
        yield DBHandle(session=db, role=role)
    finally:
        db.close()


# ---------------------------------------------------------------------------
# 启动初始化：建表 + 插入演示账号
# ---------------------------------------------------------------------------
_init_status: str = "pending"


def init_schema_and_seed() -> str:
    """
    集群里 3 个副本会同时启动，如果都去 CREATE TABLE / 插初始用户，必然打架。
    所以先抢一把 Redis 分布式锁，只有抢到的副本执行初始化。

    这就是「集群下只能执行一次的任务」的通用套路（定时任务、缓存预热同理）。
    """
    global _init_status

    from . import models  # noqa: F401  延迟导入，避免和 models → database 循环引用
    from .security import hash_password

    lock_acquired = True
    redis_client: Optional[Any] = None

    try:
        from .session_store import get_redis_client, redis_ping

        if redis_ping():
            redis_client = get_redis_client()
            # NX：只有 key 不存在时才设置成功（抢锁）；EX：30 秒后自动释放，防止死锁
            lock_acquired = bool(
                redis_client.set("init:schema:lock", settings.INSTANCE_ID, nx=True, ex=30)
            )
    except Exception:  # noqa: BLE001  Redis 不可用就退化为无锁（单机场景）
        lock_acquired = True

    if not lock_acquired:
        # 没抢到锁：等其它副本把表建好，避免自己先接流量却无表可用
        for _ in range(20):
            try:
                with write_engine.connect() as conn:
                    conn.exec_driver_sql("SELECT 1 FROM users LIMIT 1")
                _init_status = f"skipped: 表已由其它副本创建（{settings.INSTANCE_ID} 未重复执行）"
                logger.info(_init_status)
                return _init_status
            except Exception:  # noqa: BLE001
                time.sleep(1)
        _init_status = "skipped: 等待其它副本初始化超时"
        return _init_status

    try:
        Base.metadata.create_all(bind=write_engine)

        with SessionLocal(bind=write_engine) as db:
            if db.query(models.User).count() == 0:
                users = []
                if settings.SEED_DEMO_USERS:
                    users = [
                        models.User(
                            username="alice",
                            password_hash=hash_password("123456"),
                            nickname="Alice（演示账号）",
                        ),
                        models.User(
                            username="bob",
                            password_hash=hash_password("123456"),
                            nickname="Bob（演示账号）",
                        ),
                    ]
                elif settings.ADMIN_INITIAL_PASSWORD:
                    users = [
                        models.User(
                            username="admin",
                            password_hash=hash_password(settings.ADMIN_INITIAL_PASSWORD),
                            nickname="管理员",
                        )
                    ]

                if users:
                    db.add_all(users)
                    db.commit()
                    logger.info(
                        "已初始化 %s 个账号：%s",
                        len(users),
                        ", ".join(u.username for u in users),
                    )
                else:
                    logger.warning(
                        "未创建任何账号（SEED_DEMO_USERS=false 且 ADMIN_INITIAL_PASSWORD 为空）。"
                        "如需登录，请设置 ADMIN_INITIAL_PASSWORD 后清空数据库卷重新初始化。"
                    )

        _init_status = f"ok: 由 {settings.INSTANCE_ID} 建表并初始化数据"
        logger.info(_init_status)
        return _init_status
    finally:
        if redis_client is not None:
            try:
                redis_client.delete("init:schema:lock")
            except Exception:  # noqa: BLE001
                pass


def get_init_status() -> str:
    return _init_status
