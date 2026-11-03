"""接口的输入/输出结构（Pydantic v2）。前后端分离的「契约」就写在这里。"""

from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, ConfigDict, Field


class LoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=128)


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    username: str
    nickname: str = ""


class SessionOut(BaseModel):
    """把服务端 Session 档案脱敏后返回，用于教学观察。"""

    sid_prefix: str
    hits: int
    login_at: str
    login_ip: str
    ttl_seconds: int
    backend: str


class MeOut(BaseModel):
    user: UserOut
    session: SessionOut
    handled_by: str  # 哪个后端副本处理的这次请求 → 负载均衡证据


class NoteIn(BaseModel):
    title: str = Field(min_length=1, max_length=128)
    content: str = Field(default="", max_length=5000)


class NoteOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    content: str = ""
    created_at: datetime


class NoteListOut(BaseModel):
    items: List[NoteOut]
    total: int
    db_role: str  # replica / primary / primary(fallback) → 读写分离证据
    handled_by: str


class NoteCreatedOut(BaseModel):
    note: NoteOut
    db_role: str
    handled_by: str


class SystemInfoOut(BaseModel):
    instance_id: str
    session_backend: str
    session_backend_note: str
    redis_ok: bool
    db_write: str
    db_read: str
    read_replica_ok: bool
    global_request_count: int
    uptime_seconds: int
    init_status: Optional[str] = None
