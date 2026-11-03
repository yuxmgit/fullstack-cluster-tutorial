"""
★ 本教程最核心的一个文件：Session 到底存在哪儿。

同一个接口，两套实现：
    MemorySessionStore  → 存在进程内存里（单机 OK，集群必炸，用于复现 bug）
    RedisSessionStore   → 存在 Redis 里（所有副本共享，集群正确姿势）

上层 deps.py / routers/auth.py 完全不知道用的是哪一个，
所以只要改一个环境变量 SESSION_BACKEND，就能在「错误示范 / 正确示范」之间切换。
"""

import json
import secrets
import threading
import time
from abc import ABC, abstractmethod
from typing import Any, Dict, Optional

import redis

from .config import settings

KEY_PREFIX = "sess:"


def session_key(sid: str) -> str:
    """统一 key 规范：sess:<随机串>。加前缀便于监控、批量清理、和业务缓存区分。"""
    return f"{KEY_PREFIX}{sid}"


def new_session_id() -> str:
    """
    生成号码牌。
    必须用密码学安全随机数：secrets 而不是 random，也不要自增 ID / 时间戳
    （否则可以被遍历、被猜到，等于把所有人的会话交出去）。
    """
    return secrets.token_urlsafe(32)


# ---------------------------------------------------------------------------
# 抽象接口：定义「一个 Session 存储」需要提供哪些能力
# ---------------------------------------------------------------------------
class BaseSessionStore(ABC):
    name: str = "base"

    @abstractmethod
    def create(self, data: Dict[str, Any]) -> str:
        """创建档案，返回号码牌 sid。"""

    @abstractmethod
    def get(self, sid: str) -> Optional[Dict[str, Any]]:
        """凭号码牌查档案，不存在/已过期返回 None。"""

    @abstractmethod
    def save(self, sid: str, data: Dict[str, Any]) -> None:
        """回写档案（本项目用它累加 hits，顺带续期）。"""

    @abstractmethod
    def touch(self, sid: str) -> bool:
        """只续期，不改内容（滑动过期）。"""

    @abstractmethod
    def delete(self, sid: str) -> None:
        """删除档案（登出 / 管理员踢人）。"""

    @abstractmethod
    def inspect(self, sid: str) -> Dict[str, Any]:
        """教学用：把档案原文、剩余 TTL 暴露出来，让你看得见。"""


# ---------------------------------------------------------------------------
# 实现一：进程内存（错误示范）
# ---------------------------------------------------------------------------
class MemorySessionStore(BaseSessionStore):
    """
    一个 Python 字典。

    单机：完美。
    集群：backend-1 写的档案，backend-2 / backend-3 看不见 → 登录随机失效。
    """

    name = "memory"

    def __init__(self) -> None:
        self._data: Dict[str, Dict[str, Any]] = {}
        self._lock = threading.Lock()
        self._ttl = settings.SESSION_TTL_SECONDS

    def _purge_expired(self) -> None:
        now = time.time()
        expired = [k for k, v in self._data.items() if v["expires_at"] <= now]
        for k in expired:
            self._data.pop(k, None)

    def create(self, data: Dict[str, Any]) -> str:
        sid = new_session_id()
        with self._lock:
            self._purge_expired()
            self._data[sid] = {"data": dict(data), "expires_at": time.time() + self._ttl}
        return sid

    def get(self, sid: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            item = self._data.get(sid)
            if not item:
                return None
            if item["expires_at"] <= time.time():
                self._data.pop(sid, None)
                return None
            return dict(item["data"])

    def save(self, sid: str, data: Dict[str, Any]) -> None:
        with self._lock:
            if sid in self._data:
                self._data[sid] = {"data": dict(data), "expires_at": time.time() + self._ttl}

    def touch(self, sid: str) -> bool:
        with self._lock:
            item = self._data.get(sid)
            if not item:
                return False
            item["expires_at"] = time.time() + self._ttl
            return True

    def delete(self, sid: str) -> None:
        with self._lock:
            self._data.pop(sid, None)

    def inspect(self, sid: str) -> Dict[str, Any]:
        with self._lock:
            item = self._data.get(sid)
            if not item:
                return {"key": session_key(sid), "value": None, "ttl_seconds": -2, "backend": self.name}
            return {
                "key": session_key(sid),
                "sid_prefix": sid[:8],
                "value": dict(item["data"]),
                "ttl_seconds": max(0, int(item["expires_at"] - time.time())),
                "backend": self.name,
                "note": "⚠ 存在本进程内存里，其它副本看不到这条数据",
            }


# ---------------------------------------------------------------------------
# 实现二：Redis（正确示范）
# ---------------------------------------------------------------------------
class RedisSessionStore(BaseSessionStore):
    name = "redis"

    def __init__(self, client: "redis.Redis") -> None:
        self.r = client
        self._ttl = settings.SESSION_TTL_SECONDS

    def create(self, data: Dict[str, Any]) -> str:
        sid = new_session_id()
        # SETEX = SET + EXPIRE：写入的同时设置过期时间，绝不留下僵尸 key
        self.r.setex(session_key(sid), self._ttl, json.dumps(data, ensure_ascii=False))
        return sid

    def get(self, sid: str) -> Optional[Dict[str, Any]]:
        raw = self.r.get(session_key(sid))
        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            # 数据被写坏就当无效，不要让整个请求 500
            self.r.delete(session_key(sid))
            return None

    def save(self, sid: str, data: Dict[str, Any]) -> None:
        # SET 带 EX → 内容更新 + TTL 重置（滑动续期）
        self.r.set(session_key(sid), json.dumps(data, ensure_ascii=False), ex=self._ttl)

    def touch(self, sid: str) -> bool:
        return bool(self.r.expire(session_key(sid), self._ttl))

    def delete(self, sid: str) -> None:
        # 删 Redis 而不是只清 Cookie：这样一次登出，全集群立刻生效
        self.r.delete(session_key(sid))

    def inspect(self, sid: str) -> Dict[str, Any]:
        pipe = self.r.pipeline()
        pipe.get(session_key(sid))
        pipe.ttl(session_key(sid))
        raw, ttl = pipe.execute()
        if raw is None:
            return {"key": session_key(sid), "value": None, "ttl_seconds": -2, "backend": self.name}
        return {
            "key": session_key(sid),
            "sid_prefix": sid[:8],
            "value": json.loads(raw),
            "ttl_seconds": int(ttl),
            "backend": self.name,
            "note": "✅ 存在 Redis 里，所有后端副本读的是同一份数据",
        }


# ---------------------------------------------------------------------------
# Redis 连接 & 存储工厂
# ---------------------------------------------------------------------------
_redis_client: Optional["redis.Redis"] = None
_store: Optional[BaseSessionStore] = None
_backend_note: str = ""


def get_redis_client() -> "redis.Redis":
    global _redis_client
    if _redis_client is None:
        _redis_client = redis.Redis.from_url(
            settings.REDIS_URL,
            decode_responses=True,
            socket_connect_timeout=2,
            socket_timeout=2,
            health_check_interval=30,
        )
    return _redis_client


def redis_ping() -> bool:
    try:
        return bool(get_redis_client().ping())
    except Exception:
        return False


def init_store() -> BaseSessionStore:
    """
    根据配置构建存储。Redis 连不上时自动降级为内存并给出醒目提示，
    保证「忘了起 Redis 也能先跑起来」——但降级后在集群里会掉登录，这本身就是教学点。
    """
    global _store, _backend_note

    if settings.SESSION_BACKEND == "memory":
        _store = MemorySessionStore()
        _backend_note = "已按配置使用进程内存（实验模式：3 个副本各自记账，会随机掉登录）"
    elif redis_ping():
        _store = RedisSessionStore(get_redis_client())
        _backend_note = "集中式 Session：所有副本共享 Redis 中的 sess:* 档案"
    else:
        _store = MemorySessionStore()
        _backend_note = "⚠ Redis 连接失败，已降级为进程内存（集群下会掉登录）"

    return _store


def get_store() -> BaseSessionStore:
    return _store if _store is not None else init_store()


def store_note() -> str:
    get_store()
    return _backend_note
