#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
删除 LHG Bot / Hztech Bot 在库中的全部业务数据（tradingbot_id 与 account_id 均为
simpleserver-lhg、simpleserver-hztech）。

用法：在 server 目录下执行  python purge_simpleserver_bots.py
依赖：与线上一致的数据库环境（HZTECH_DB_BACKEND / DATABASE_URL 等）。

说明：不修改 users.linked_account_ids；若客户仍绑定上述 id，
请在管理界面另行调整。
"""
from __future__ import annotations

import sys

from db import get_conn
from db_backend import IS_POSTGRES

from purge_account_history import _exec_count, purge_account_fully

SIMPLESERVER_BOT_IDS: tuple[str, ...] = ("simpleserver-lhg", "simpleserver-hztech")


def purge_simpleserver_bots() -> dict[str, dict[str, int]]:
    conn = get_conn()
    if not IS_POSTGRES:
        conn.execute("PRAGMA busy_timeout = 60000")
    out: dict[str, dict[str, int]] = {}
    try:
        for bid in SIMPLESERVER_BOT_IDS:
            c = purge_account_fully(conn, bid)
            n_list = _exec_count(
                conn,
                "DELETE FROM account_list WHERE account_id = ?",
                (bid,),
            )
            if n_list:
                c["account_list"] = n_list
            out[bid] = c
            conn.commit()
            print(f"{bid}: 共删除 {sum(c.values())} 行 -> {c}")
        return out
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def main() -> int:
    print(f"后端: {'PostgreSQL' if IS_POSTGRES else 'SQLite'}")
    print("清理 simpleserver-lhg / simpleserver-hztech …")
    purge_simpleserver_bots()
    print("完成。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
