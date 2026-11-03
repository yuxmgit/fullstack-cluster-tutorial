"""
认证与会话接口 —— 集中式 Session 的完整闭环：登录 / 查询 / 续期 / 登出 / 透视。
"""

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from sqlalchemy.orm import Session

from ..config import settings
from ..database import get_write_db
from ..deps import get_current_user, get_session_id
from ..models import User
from ..schemas import LoginIn, MeOut, SessionOut, UserOut
from ..security import client_ip, verify_password
from ..session_store import get_store

router = APIRouter()


def _user_out(user: User) -> UserOut:
    return UserOut(id=user.id, username=user.username, nickname=user.nickname or user.username)


@router.post("/login")
def login(
    payload: LoginIn,
    request: Request,
    response: Response,
    db: Session = Depends(get_write_db),
):
    user = db.query(User).filter(User.username == payload.username).one_or_none()
    if user is None or not verify_password(payload.password, user.password_hash):
        # 不区分「用户不存在」和「密码错误」，避免账号枚举
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="用户名或密码错误")

    store = get_store()

    # ① 服务端创建档案（写 Redis / 内存）
    sid = store.create(
        {
            "user_id": user.id,
            "username": user.username,
            "nickname": user.nickname or user.username,
            "login_at": datetime.now().isoformat(timespec="seconds"),
            "login_ip": client_ip(request),
            "hits": 0,
        }
    )

    # ② 浏览器只拿到「号码牌」，拿不到任何用户信息
    response.set_cookie(
        key=settings.SESSION_COOKIE_NAME,
        value=sid,
        max_age=settings.SESSION_TTL_SECONDS,
        httponly=True,          # JS 读不到 → 防 XSS 偷会话
        samesite="lax",         # 防 CSRF；跨站场景需 None + Secure
        secure=settings.COOKIE_SECURE,  # HTTP 环境必须 False，否则 Cookie 不会被保存
        path="/",
    )

    return {
        "ok": True,
        "user": _user_out(user).model_dump(),
        "session_id_prefix": sid[:8],
        "handled_by": settings.INSTANCE_ID,
        "session_backend": store.name,
    }


@router.post("/logout")
def logout(request: Request, response: Response):
    sid = get_session_id(request)
    if sid:
        # 关键：删的是服务端档案，不只是浏览器 Cookie
        get_store().delete(sid)
    response.delete_cookie(settings.SESSION_COOKIE_NAME, path="/")
    return {"ok": True, "handled_by": settings.INSTANCE_ID}


@router.get("/me", response_model=MeOut)
def me(request: Request, session: dict = Depends(get_current_user)):
    sid = get_session_id(request) or ""
    store = get_store()
    detail = store.inspect(sid)

    return MeOut(
        user=UserOut(
            id=session["user_id"],
            username=session["username"],
            nickname=session.get("nickname") or session["username"],
        ),
        session=SessionOut(
            sid_prefix=sid[:8],
            hits=session.get("hits", 0),
            login_at=session.get("login_at", ""),
            login_ip=session.get("login_ip", ""),
            ttl_seconds=int(detail.get("ttl_seconds", -1)),
            backend=store.name,
        ),
        handled_by=settings.INSTANCE_ID,
    )


@router.get("/session")
def session_detail(request: Request, session: dict = Depends(get_current_user)):
    """
    教学接口：把服务端 Session 档案原文、TTL 直接返回。

    真实项目不要暴露这种接口（会泄露会话结构），这里只是为了让你「看得见」。
    """
    # 生产环境（ENABLE_DEBUG_ENDPOINTS=false）直接当不存在，
    # 避免把会话档案结构暴露给公网。
    if not settings.ENABLE_DEBUG_ENDPOINTS:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not Found")

    sid = get_session_id(request) or ""
    detail = get_store().inspect(sid)
    detail["handled_by"] = settings.INSTANCE_ID
    return detail
