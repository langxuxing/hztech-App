#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""将 users 表中所有账号的 password_hash 统一为 SHA256(i23321)。

在 server 目录执行: python3 sync_all_passwords_i23321.py

警告：会覆盖所有用户已修改的密码，仅用于运维一次性对齐或开发环境。
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SERVER_DIR))

import db  # noqa: E402


def main() -> None:
    h = hashlib.sha256(b"i23321").hexdigest()
    conn = db.get_conn()
    try:
        (total,) = conn.execute("SELECT COUNT(*) FROM users").fetchone()
        conn.execute("UPDATE users SET password_hash = ?", (h,))
        conn.commit()
        print(f"已更新 {total} 条用户密码哈希为 i23321（SHA256）")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
