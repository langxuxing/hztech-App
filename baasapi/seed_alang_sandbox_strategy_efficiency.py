#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
仅向数据库写入「阿郎测试」账户（account_id=Alang_Sandbox）策略能效接口所需源数据：
  - account_daily_performance（北京日历 day，balance_changed 为 USDT 日增量）
  - account_month_balance_baseline（UTC 自然月初资金/权益，作收益率分母）
  - 可选：删除该账户近期 account_balance_snapshots，避免与 ADP 混算 sod

不修改 market_daily_bars（全站共用 K 线）。

依赖：与线上一致（HZTECH_DB_BACKEND / DATABASE_URL 或 SQLite 路径）。

用法（在 baasapi 目录下）:
  python seed_alang_sandbox_strategy_efficiency.py
  python seed_alang_sandbox_strategy_efficiency.py --days 30
  python seed_alang_sandbox_strategy_efficiency.py --dry-run
"""
from __future__ import annotations

import argparse
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

import db  # noqa: E402
from db_backend import IS_POSTGRES  # noqa: E402

ACCOUNT_ID = "Alang_Sandbox"
DEFAULT_INITIAL = 5000.0
INSTRUMENT_ID = "PEPE-USDT-SWAP"


def _parse_date(s: str) -> date:
    y, m, d = (int(x) for x in s.strip().split("-")[:3])
    return date(y, m, d)


def _day_range(end: date, n_days: int) -> tuple[date, date]:
    """含首尾共 n_days 天：start .. end。"""
    if n_days < 1:
        raise ValueError("days 须 >= 1")
    start = end - timedelta(days=n_days - 1)
    return start, end


def _months_in_range(start: date, end: date) -> list[str]:
    seen: set[str] = set()
    d = start
    while d <= end:
        seen.add(f"{d.year:04d}-{d.month:02d}")
        d += timedelta(days=1)
    return sorted(seen)


def _delta_for_index(i: int) -> float:
    """确定性演示日增量（与旧 SQL 脚本同构）。"""
    return round(8.0 + (i * 13) % 35 + (i % 3) * 2.5, 2)


def seed(
    conn,
    *,
    start: date,
    end: date,
    initial_balance: float,
    delete_snapshots: bool,
) -> dict[str, int]:
    start_s = start.isoformat()
    end_s = end.isoformat()
    counts: dict[str, int] = {}

    cur = conn.execute(
        "DELETE FROM account_daily_performance WHERE account_id = ? AND day >= ? AND day <= ?",
        (ACCOUNT_ID, start_s, end_s),
    )
    counts["account_daily_performance_deleted"] = int(cur.rowcount)

    if delete_snapshots:
        conn.execute(
            "DELETE FROM account_balance_snapshots WHERE account_id = ? AND snapshot_at >= ?",
            (ACCOUNT_ID, f"{start_s}T00:00:00.000Z"),
        )

    months = _months_in_range(start, end)
    for ym in months:
        conn.execute(
            "DELETE FROM account_month_balance_baseline WHERE account_id = ? AND year_month = ?",
            (ACCOUNT_ID, ym),
        )

    rec = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    for ym in months:
        if IS_POSTGRES:
            conn.execute(
                """INSERT INTO account_month_balance_baseline
                   (account_id, year_month, initial_equity, initial_balance, recorded_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT (account_id, year_month) DO UPDATE SET
                     initial_equity = EXCLUDED.initial_equity,
                     initial_balance = EXCLUDED.initial_balance,
                     recorded_at = EXCLUDED.recorded_at""",
                (ACCOUNT_ID, ym, initial_balance, initial_balance, rec),
            )
        else:
            conn.execute(
                """INSERT OR REPLACE INTO account_month_balance_baseline
                   (account_id, year_month, initial_equity, initial_balance, recorded_at)
                   VALUES (?, ?, ?, ?, ?)""",
                (ACCOUNT_ID, ym, initial_balance, initial_balance, rec),
            )
    counts["account_month_balance_baseline_upserted"] = len(months)

    n_ins = 0
    d = start
    i = 0
    while d <= end:
        delta = _delta_for_index(i)
        conn.execute(
            """INSERT INTO account_daily_performance
               (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at)
               VALUES (?, ?, 0, 0, ?, ?, datetime('now'))""",
            (ACCOUNT_ID, d.isoformat(), delta, INSTRUMENT_ID),
        )
        n_ins += 1
        d += timedelta(days=1)
        i += 1
    counts["account_daily_performance_inserted"] = n_ins
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(
        description="写入 Alang_Sandbox 策略能效源数据（仅该 account_id）",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=30,
        help="最近若干自然日（含今天 UTC），默认 30",
    )
    parser.add_argument(
        "--end-date",
        type=str,
        default="",
        help="结束日 YYYY-MM-DD（默认今天 UTC）",
    )
    parser.add_argument(
        "--initial",
        type=float,
        default=DEFAULT_INITIAL,
        help=f"月初基准 USDT（默认 {DEFAULT_INITIAL}，与 Account_List 阿郎测试一致）",
    )
    parser.add_argument(
        "--keep-snapshots",
        action="store_true",
        help="不删除该账户近期 account_balance_snapshots（默认会删 start 日起的快照以免混算）",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="只打印将写入的区间与行数，不连库",
    )
    args = parser.parse_args()

    if args.end_date.strip():
        end = _parse_date(args.end_date)
    else:
        end = datetime.now(timezone.utc).date()
    start, end = _day_range(end, args.days)

    if args.dry_run:
        print(
            f"[dry-run] account_id={ACCOUNT_ID} days={args.days} "
            f"range={start.isoformat()}..{end.isoformat()} "
            f"months={_months_in_range(start, end)} initial={args.initial} "
            f"delete_snapshots={not args.keep_snapshots}"
        )
        return 0

    db.init_db()
    conn = db.get_conn()
    if not IS_POSTGRES:
        conn.execute("PRAGMA busy_timeout = 60000")
    try:
        out = seed(
            conn,
            start=start,
            end=end,
            initial_balance=args.initial,
            delete_snapshots=not args.keep_snapshots,
        )
        conn.commit()
        print(f"后端: {'PostgreSQL' if IS_POSTGRES else 'SQLite'}")
        print(f"已写入 {ACCOUNT_ID}: {out}")
        return 0
    except Exception as e:
        conn.rollback()
        print(f"错误: {e}", file=sys.stderr)
        return 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
