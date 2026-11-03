"""
留言板接口 —— 演示「写主库、读从库」以及越权防护。
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func
from sqlalchemy.orm import Session

from ..config import settings
from ..database import DBHandle, get_read_db, get_write_db
from ..deps import get_current_user
from ..models import Note
from ..schemas import NoteCreatedOut, NoteIn, NoteListOut, NoteOut

router = APIRouter()


@router.get("", response_model=NoteListOut)
def list_notes(
    handle: DBHandle = Depends(get_read_db),
    session: dict = Depends(get_current_user),
):
    db = handle.session
    # 一定要按 user_id 过滤：不是「查全部再让前端筛」，否则任何人改个请求就能看别人数据
    base = db.query(Note).filter(Note.user_id == session["user_id"])
    total = db.query(func.count(Note.id)).filter(Note.user_id == session["user_id"]).scalar() or 0
    rows = base.order_by(Note.id.desc()).limit(100).all()

    return NoteListOut(
        items=[NoteOut.model_validate(r) for r in rows],
        total=int(total),
        db_role=handle.role,          # replica / primary / primary(fallback)
        handled_by=settings.INSTANCE_ID,
    )


@router.post("", response_model=NoteCreatedOut, status_code=status.HTTP_201_CREATED)
def create_note(
    payload: NoteIn,
    db: Session = Depends(get_write_db),
    session: dict = Depends(get_current_user),
):
    note = Note(
        user_id=session["user_id"],
        title=payload.title.strip(),
        content=payload.content or "",
    )
    db.add(note)
    db.commit()
    db.refresh(note)

    # 注意：这里返回刚写入的完整对象，前端可以直接「乐观更新」列表，
    # 不必马上再查一次 —— 因为主从复制有延迟，立刻读从库可能读不到（教程 04 章）。
    return NoteCreatedOut(
        note=NoteOut.model_validate(note),
        db_role="primary",
        handled_by=settings.INSTANCE_ID,
    )


@router.delete("/{note_id}")
def delete_note(
    note_id: int,
    db: Session = Depends(get_write_db),
    session: dict = Depends(get_current_user),
):
    note = (
        db.query(Note)
        .filter(Note.id == note_id, Note.user_id == session["user_id"])
        .one_or_none()
    )
    if note is None:
        # 别人的留言也返回 404，不泄露「这条数据存在」
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="留言不存在")

    db.delete(note)
    db.commit()
    return {"ok": True, "deleted_id": note_id, "handled_by": settings.INSTANCE_ID}
