#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性写入团队账号（可重复执行：已存在则更新密码、角色与绑定）。

在 server 目录执行: python3 seed_team_users.py

账号说明（登录名为小写）：
- admin（管理员）→ 与 users.json 缺省一致，密码同步为 i23321
- dongjie（董杰VIP·客户）→ 仅可见 OKX_HzTech_Moneyflow@004
- chengwenbin（程文彬VIP·客户）→ 仅可见 OKX_HzTech_Moneyflow@002
- linsong（林松·交易员）
- liuhengguo（刘恒果·交易员）
- alang（阿郎·策略分析师）

缺省登录密码均为：i23321（首次登录后建议修改）。
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SERVER_DIR))

import db  # noqa: E402

# linked_account_ids 须与 /api/tradingbots 中 tradingbot_id（即 Account_List 的 account_id）一致
TEAM: list[dict[str, object]] = [
    {
        "username": "admin",
        "password": "i23321",
        "role": "admin",
        "linked": [],
    },
    {
        "username": "dongjie",
        "password": "i23321",
        "role": "customer",
        "linked": ["OKX_HzTech_Moneyflow@004"],
    },
    {
        "username": "chengwenbin",
        "password": "i23321",
        "role": "customer",
        "linked": ["OKX_HzTech_Moneyflow@002"],
    },
    {
        "username": "linsong",
        "password": "i23321",
        "role": "trader",
        "linked": [],
    },
    {
        "username": "liuhengguo",
        "password": "i23321",
        "role": "trader",
        "linked": [],
    },
    {
        "username": "alang",
        "password": "i23321",
        "role": "strategy_analyst",
        "linked": [],
    },
]


def main() -> None:
    for spec in TEAM:
        u = str(spec["username"]).strip()
        pwd = str(spec["password"])
        role = str(spec["role"]).strip().lower()
        linked = spec.get("linked") or []
        if not isinstance(linked, list):
            linked = []
        h = hashlib.sha256(pwd.encode()).hexdigest()
        links_json = json.dumps(
            [str(x).strip() for x in linked if str(x).strip()],
            ensure_ascii=False,
        )
        links_for_create: list[str] = (
            [str(x).strip() for x in linked if str(x).strip()]
            if role == "customer"
            else []
        )
        created = db.user_create(
            u,
            h,
            role=role,
            linked_account_ids=links_for_create,
        )
        if not created:
            conn = db.get_conn()
            try:
                conn.execute(
                    """
                    UPDATE users SET password_hash = ?, role = ?,
                    linked_account_ids = ?
                    WHERE LOWER(TRIM(username)) = LOWER(?)
                    """,
                    (
                        h,
                        role,
                        links_json if role == "customer" else "[]",
                        u,
                    ),
                )
                conn.commit()
            finally:
                conn.close()
            print(f"已更新: {u} ({role})")
        else:
            print(f"已创建: {u} ({role})")


if __name__ == "__main__":
    main()
