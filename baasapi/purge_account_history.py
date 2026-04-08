#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按账户清理库内历史数据（account_* / tradingbot_* / strategy_events）。
用法：在 baasapi 目录下执行  python purge_account_history.py
依赖：与线上相同的数据库环境（HZTECH_DB_BACKEND / DATABASE_URL 等）。
"""
from __future__ import annotations

import sys
from datetime import date, datetime, timezone
from typing import Sequence

from db import get_conn
from db_backend import IS_POSTGRES


def _month_start(y: int, m: int) -> date:
    return date(y, m, 1)


def _cutoff_ms(d: date) -> int:
    """当日 00:00:00 UTC 对应的毫秒时间戳（与 u_time_ms 对齐）。"""
    dt = datetime(d.year, d.month, d.day, tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def _month_str(d: date) -> str:
    return f"{d.year:04d}-{d.month:02d}"


# 全量删除历史（保留 account_list 元数据）
FULL_PURGE_ACCOUNT_IDS: tuple[str, ...] = (
    "Alang_Sandbox",
    "Forest_Sandbox",
    "Forest_Live",
    "Guoguo_Live",
    "HzTech_Moneyflow@005",
)

# (account_id, 保留从该年-月-日起的数据，此前一律删除)
PARTIAL_RETAIN_FROM: tuple[tuple[str, tuple[int, int, int]], ...] = (
    ("HzTech_MainRepo", (2026, 2, 1)),
    ("Hztech_Devops", (2026, 2, 1)),
    ("HzTech_Moneyflow@001", (2026, 3, 1)),
    ("HzTech_Moneyflow@002", (2026, 3, 1)),
    ("HzTech_Moneyflow@003", (2026, 4, 1)),
    ("HzTech_Moneyflow@004", (2026, 4, 1)),
    ("Dong_Live", (2026, 4, 1)),
)


def _exec_count(conn, sql: str, params: Sequence[object]) -> int:
    cur = conn.execute(sql, params)
    return int(cur.rowcount) if cur.rowcount is not None and cur.rowcount >= 0 else 0


def purge_account_fully(conn, account_id: str, bot_id: str | None = None) -> dict[str, int]:
    bid = bot_id if bot_id is not None else account_id
    counts: dict[str, int] = {}
    counts["account_daily_performance"] = _exec_count(
        conn,
        "DELETE FROM account_daily_performance WHERE account_id = ?",
        (account_id,),
    )
    counts["account_balance_snapshots"] = _exec_count(
        conn,
        "DELETE FROM account_balance_snapshots WHERE account_id = ?",
        (account_id,),
    )
    counts["account_open_positions_snapshots"] = _exec_count(
        conn,
        "DELETE FROM account_open_positions_snapshots WHERE account_id = ?",
        (account_id,),
    )
    counts["account_month_balance_baseline"] = _exec_count(
        conn,
        "DELETE FROM account_month_balance_baseline WHERE account_id = ?",
        (account_id,),
    )
    counts["account_positions_history"] = _exec_count(
        conn,
        "DELETE FROM account_positions_history WHERE account_id = ?",
        (account_id,),
    )
    counts["account_season"] = _exec_count(
        conn,
        "DELETE FROM account_season WHERE account_id = ?",
        (account_id,),
    )
    counts["tradingbot_mgr"] = _exec_count(
        conn,
        "DELETE FROM tradingbot_mgr WHERE account_id = ?",
        (account_id,),
    )
    counts["tradingbot_profit_snapshots"] = _exec_count(
        conn,
        "DELETE FROM tradingbot_profit_snapshots WHERE bot_id = ?",
        (bid,),
    )
    counts["strategy_events"] = _exec_count(
        conn,
        "DELETE FROM strategy_events WHERE bot_id = ?",
        (bid,),
    )
    return counts


def purge_account_before(
    conn,
    account_id: str,
    retain_from: date,
    bot_id: str | None = None,
) -> dict[str, int]:
    """删除 retain_from 当日 00:00 (UTC) 之前的记录；从该日起及之后保留。"""
    bid = bot_id if bot_id is not None else account_id
    day_iso = retain_from.isoformat()
    ym_keep = _month_str(retain_from)
    ms = _cutoff_ms(retain_from)
    counts: dict[str, int] = {}

    counts["account_daily_performance"] = _exec_count(
        conn,
        "DELETE FROM account_daily_performance WHERE account_id = ? AND day < ?",
        (account_id, day_iso),
    )
    counts["account_balance_snapshots"] = _exec_count(
        conn,
        "DELETE FROM account_balance_snapshots WHERE account_id = ? AND snapshot_at < ?",
        (account_id, day_iso),
    )
    counts["account_open_positions_snapshots"] = _exec_count(
        conn,
        "DELETE FROM account_open_positions_snapshots WHERE account_id = ? AND snapshot_at < ?",
        (account_id, day_iso),
    )
    counts["account_month_balance_baseline"] = _exec_count(
        conn,
        "DELETE FROM account_month_balance_baseline WHERE account_id = ? AND year_month < ?",
        (account_id, ym_keep),
    )
    ph_sql = (
        "DELETE FROM account_positions_history WHERE account_id = ? "
        "AND CAST(u_time_ms AS BIGINT) < ?"
        if IS_POSTGRES
        else "DELETE FROM account_positions_history WHERE account_id = ? "
        "AND CAST(u_time_ms AS INTEGER) < ?"
    )
    counts["account_positions_history"] = _exec_count(conn, ph_sql, (account_id, ms))

    # 已结束且结束时间早于保留起点的赛季整行删除（跨保留线且仍进行中的赛季保留）
    counts["account_season"] = _exec_count(
        conn,
        "DELETE FROM account_season WHERE account_id = ? "
        "AND stopped_at IS NOT NULL AND stopped_at < ?",
        (account_id, day_iso),
    )

    counts["tradingbot_mgr"] = _exec_count(
        conn,
        "DELETE FROM tradingbot_mgr WHERE account_id = ? AND started_at < ?",
        (account_id, day_iso),
    )
    counts["tradingbot_profit_snapshots"] = _exec_count(
        conn,
        "DELETE FROM tradingbot_profit_snapshots WHERE bot_id = ? AND snapshot_at < ?",
        (bid, day_iso),
    )
    counts["strategy_events"] = _exec_count(
        conn,
        "DELETE FROM strategy_events WHERE bot_id = ? AND created_at < ?",
        (bid, day_iso),
    )
    return counts


def main() -> int:
    conn = get_conn()
    if not IS_POSTGRES:
        conn.execute("PRAGMA busy_timeout = 60000")
    try:
        print(f"后端: {'PostgreSQL' if IS_POSTGRES else 'SQLite'}")
        total: dict[str, dict[str, int]] = {}

        print("\n=== 全量清除历史 ===")
        for aid in FULL_PURGE_ACCOUNT_IDS:
            c = purge_account_fully(conn, aid)
            total[aid] = c
            print(f"{aid}: {sum(c.values())} 行 -> {c}")
            conn.commit()

        print("\n=== 按截止日期清除（保留该日及之后） ===")
        for aid, ymd in PARTIAL_RETAIN_FROM:
            d = date(ymd[0], ymd[1], ymd[2])
            c = purge_account_before(conn, aid, d)
            total[f"{aid} (before {d.isoformat()})"] = c
            print(f"{aid} 清除 {d.isoformat()} 之前: {sum(c.values())} 行 -> {c}")
            conn.commit()

        print("\n完成。")
        return 0
    except Exception as e:
        conn.rollback()
        print(f"错误: {e}", file=sys.stderr)
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
