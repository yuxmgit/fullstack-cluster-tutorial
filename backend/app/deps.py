"""
依赖注入：把「从 Cookie 取号码牌 → 去 Redis 查档案 → 得到当前用户」这段逻辑收敛到这里。

业务路由只要写 `session = Depends(get_current_user)`，
不用关心 Session 存在 Redis 还是内存，也不用关心是哪个副本在处理。
"""

from typing import Optional

from fastapi import HTTPException, Request, status

from .config import settings
from .session_store import get_store


def get_session_id(request: Request) -> Optional[str]:
    return request.cookies.get(settings.SESSION_COOKIE_NAME)


def get_current_user(request: Request) -> dict:
    """
    认证的核心三行（对照教程 02 章第 2.5 节）：

        1. 从 Cookie 取 session_id（浏览器自动带的「号码牌」）
        2. 用号码牌去共享存储查「档案」
        3. 查不到 = 未登录 / 已过期
    """
    sid = get_session_id(request)
    if not sid:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="未登录")

    store = get_store()
    data = store.get(sid)
    if not data:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="登录已过期，请重新登录",
        )

    # 每次有效访问：计数 +1 并写回，顺带续期（滑动过期）
    # 3 个副本改的是同一份 Redis 数据，所以这个计数不会因为换副本而重置。
    data["hits"] = int(data.get("hits", 0)) + 1
    store.save(sid, data)

    return data


def get_optional_user(request: Request) -> Optional[dict]:
    """探针类接口用：登录了就返回用户，没登录也不报错。"""
    sid = get_session_id(request)
    if not sid:
        return None
    try:
        return get_store().get(sid)
    except Exception:  # noqa: BLE001
        return None
