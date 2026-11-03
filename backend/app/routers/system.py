"""
系统与架构探针 —— 用来「看见」集群内部发生了什么。

    /health  健康检查（只检查本进程，绝不查数据库，否则数据库一抖全站雪崩）
    /info    实例信息：谁在处理请求、Session 后端、Redis/从库是否可用、全局请求计数
"""

import re
import threading
import time

from fastapi import APIRouter

from ..config import settings
from ..database import get_init_status, read_replica_ok
from ..schemas import SystemInfoOut
from ..session_store import get_redis_client, get_store, redis_ping, store_note

router = APIRouter()

START_TIME = time.time()
_local_counter = {"value": 0}
_counter_lock = threading.Lock()


def _safe_url(url: str) -> str:
    """把连接串里的密码替换成 ***，避免探针接口泄露凭据。"""
    return re.sub(r"://([^:/@]+):[^@]*@", r"://\1:***@", url)


def _bump_local_counter() -> int:
    with _counter_lock:
        _local_counter["value"] += 1
        return _local_counter["value"]


@router.get("/health")
def health():
    """
    只证明「我这个进程还活着」。
    不要在这里查数据库/Redis：否则依赖一抖动，所有副本会被同时判定为不健康。
    """
    return {"status": "ok", "instance": settings.INSTANCE_ID}


@router.get("/info", response_model=SystemInfoOut)
def info():
    store = get_store()
    redis_ok = redis_ping()

    # 全局请求计数：放在 Redis 里，所有副本共享；Redis 不可用时退化为进程内计数
    if redis_ok:
        try:
            count = int(get_redis_client().incr("stats:requests"))
        except Exception:  # noqa: BLE001
            count = _bump_local_counter()
    else:
        count = _bump_local_counter()

    masked = not settings.ENABLE_DEBUG_ENDPOINTS

    return SystemInfoOut(
        instance_id=settings.INSTANCE_ID,
        session_backend=store.name,
        session_backend_note=store_note(),
        redis_ok=redis_ok,
        # 连接串里虽然已把密码替换成 ***，但仍会暴露内网主机名与账号，
        # 生产环境统一返回 hidden。
        db_write="hidden" if masked else _safe_url(settings.DB_WRITE_URL),
        db_read="hidden" if masked else _safe_url(settings.DB_READ_URL),
        read_replica_ok=read_replica_ok(),
        global_request_count=count,
        uptime_seconds=int(time.time() - START_TIME),
        init_status="hidden" if masked else get_init_status(),
    )
