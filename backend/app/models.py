"""
数据表定义。只放「必须持久化」的东西，不放任何会话状态。
"""

from datetime import datetime

from sqlalchemy import Column, DateTime, Integer, String, Text

from .database import Base


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(64), unique=True, nullable=False, index=True)
    password_hash = Column(String(256), nullable=False)  # 绝不存明文密码
    nickname = Column(String(64), default="")
    created_at = Column(DateTime, default=datetime.now, nullable=False)


class Note(Base):
    """留言板。用来演示：写走主库、读走从库。"""

    __tablename__ = "notes"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, nullable=False, index=True)  # 每个查询都按它过滤，防越权
    title = Column(String(128), nullable=False)
    content = Column(Text, default="")
    created_at = Column(DateTime, default=datetime.now, nullable=False, index=True)
