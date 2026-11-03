"""
密码哈希与客户端 IP 工具。

不引入 passlib/bcrypt，只用标准库，保证「装好依赖就能跑」，同时避免明文密码。
"""

import base64
import hashlib
import hmac
import os

from fastapi import Request

_ALGO = "pbkdf2_sha256"
_ITERATIONS = 120_000


def hash_password(password: str) -> str:
    """返回 pbkdf2_sha256$迭代次数$盐$摘要，盐随机，每个用户不同。"""
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, _ITERATIONS)
    return f"{_ALGO}${_ITERATIONS}${base64.b64encode(salt).decode()}${base64.b64encode(digest).decode()}"


def verify_password(password: str, stored: str) -> bool:
    """恒定时间比较，防止通过响应时间猜测密码。"""
    try:
        algo, iterations, salt_b64, digest_b64 = stored.split("$")
        if algo != _ALGO:
            return False
        digest = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            base64.b64decode(salt_b64),
            int(iterations),
        )
        return hmac.compare_digest(digest, base64.b64decode(digest_b64))
    except (ValueError, TypeError):
        return False


def client_ip(request: Request) -> str:
    """
    取真实客户端 IP。

    请求经过 Nginx 后，request.client.host 会变成 Nginx 容器 IP，
    真实 IP 在 X-Forwarded-For 里（格式：client, proxy1, proxy2），取第一个。
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    real_ip = request.headers.get("x-real-ip")
    if real_ip:
        return real_ip.strip()
    return request.client.host if request.client else "unknown"
