"""
所有配置的唯一入口。

设计要点（对应教程 03 章「无状态改造清单」最后一条）：
   配置不写死在代码里，全部来自环境变量。
   同一份镜像，在本地、单机、集群三种环境里靠环境变量切换行为。
"""

import os
import socket
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

# 本地开发：加载 backend/.env；Docker 里没有这个文件，直接读环境变量
load_dotenv(Path(__file__).resolve().parent.parent / ".env")


def _env(key: str, default: str) -> str:
    value = os.getenv(key)
    return value if value not in (None, "") else default


def _env_bool(key: str, default: bool) -> bool:
    return _env(key, str(default)).strip().lower() in ("1", "true", "yes", "on")


def _env_int(key: str, default: int) -> int:
    try:
        return int(_env(key, str(default)))
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    # --- 数据库：读写分离的两个连接串 ---
    DB_WRITE_URL: str = field(default_factory=lambda: _env("DB_WRITE_URL", "sqlite:///./demo.db"))
    DB_READ_URL: str = field(default_factory=lambda: _env("DB_READ_URL", "sqlite:///./demo.db"))

    # --- Redis ---
    REDIS_URL: str = field(default_factory=lambda: _env("REDIS_URL", "redis://localhost:6379/0"))

    # --- Session ---
    # redis = 集中式（正确示范）；memory = 进程内字典（错误示范，用于复现集群掉登录）
    SESSION_BACKEND: str = field(default_factory=lambda: _env("SESSION_BACKEND", "redis").strip().lower())
    SESSION_TTL_SECONDS: int = field(default_factory=lambda: _env_int("SESSION_TTL_SECONDS", 1800))
    SESSION_COOKIE_NAME: str = field(default_factory=lambda: _env("SESSION_COOKIE_NAME", "session_id"))

    # --- Cookie 安全属性 ---
    # 本地 HTTP 必须 False，否则浏览器不会保存这个 Cookie（新手最常踩的坑）
    COOKIE_SECURE: bool = field(default_factory=lambda: _env_bool("COOKIE_SECURE", False))

    # --- 跨域白名单（生产走 Nginx 同源时用不到，本地开发需要）---
    CORS_ORIGINS: list[str] = field(
        default_factory=lambda: [
            o.strip()
            for o in _env(
                "CORS_ORIGINS",
                "http://localhost:5173,http://127.0.0.1:5173,http://localhost:8080",
            ).split(",")
            if o.strip()
        ]
    )

    # --- 初始化数据（上公网前必须注意的安全开关）---
    # 教学环境默认插入 alice / bob（密码 123456）。
    # 生产环境必须设 SEED_DEMO_USERS=false，否则等于给公网留了一个公开后门。
    SEED_DEMO_USERS: bool = field(default_factory=lambda: _env_bool("SEED_DEMO_USERS", True))
    # 关闭演示账号后，用这个密码创建唯一的管理员账号 admin（为空则不创建）
    ADMIN_INITIAL_PASSWORD: str = field(
        default_factory=lambda: _env("ADMIN_INITIAL_PASSWORD", "")
    )

    # --- 调试 / 教学接口开关 ---
    # /api/auth/session 会原样返回会话档案，/api/system/info 会返回连接串。
    # 生产环境设为 false，避免把内部结构暴露到公网。
    ENABLE_DEBUG_ENDPOINTS: bool = field(
        default_factory=lambda: _env_bool("ENABLE_DEBUG_ENDPOINTS", True)
    )

    # --- 实例标识：集群里区分「这次请求是谁处理的」 ---
    INSTANCE_ID: str = field(default_factory=lambda: _env("INSTANCE_ID", socket.gethostname()))

    @property
    def is_sqlite(self) -> bool:
        return self.DB_WRITE_URL.startswith("sqlite")

    @property
    def same_db_for_read_write(self) -> bool:
        return self.DB_READ_URL == self.DB_WRITE_URL


settings = Settings()
