#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性添加用户到数据库。用法: 在 server 目录下执行 python add_user.py"""
import hashlib
import sys

from db import user_create

def main():
    username = "linsong"
    password = "Ls@2026"
    pwd_hash = hashlib.sha256(password.encode()).hexdigest()
    if user_create(username, pwd_hash):
        print(f"用户 {username} 已创建。")
    else:
        print(f"用户 {username} 已存在，无需重复创建。")
        sys.exit(0)

if __name__ == "__main__":
    main()
