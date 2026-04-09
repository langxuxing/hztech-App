#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构造 Alang_Sandbox 仅 2026 年 3–4 月演示数据（不碰其他账户）：
  - 账户初始资金（Account_List / 盈亏分母）：4000；3 月初、4 月初月度基准：4000 / 5000
    （account_month_balance_baseline）
  - 每日 balance 增量：30 + U[1,10]；权益日增量：5 + U[-10,+10]
  - 启动时生成两个随机整数作为 3 月、4 月日序列 RNG 种子（可复现）
  - 写入 account_balance_snapshots、account_daily_performance
  - 日期范围：2026-03-01 ～ 2026-04-09（整月 3 月 + 4 月前 9 天）
  - ADP 列：net_realized_pnl / close_pos_count / equlity_changed / balance_changed /
    balance_changed_pct / pnl_pct 一并写入（pnl_pct 口径与 db 重建一致：net_realized_pnl÷当月月初基准×100）

用法（在 baasapi 目录下）:
  python seed_alang_sandbox_mar_apr_2026.py
  python seed_alang_sandbox_mar_apr_2026.py --dry-run
"""
from __future__ import annotations

import argparse
import random
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

import db  # noqa: E402
from db_backend import IS_POSTGRES  # noqa: E402

ACCOUNT_ID = "Alang_Sandbox"
YEAR = 2026
MAR_BASE = 4000.0
APR_BASE = 5000.0
# 含当日：整月 3 月 + 4 月 1..9
LAST_DAY = date(YEAR, 4, 9)
INSTRUMENT_ID = "PEPE-USDT-SWAP"


def _snapshot_ts(day: date, hour: int = 8) -> str:
    dt = datetime(
        day.year, day.month, day.day, hour, 0, 0, tzinfo=timezone.utc
    )
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _month_days(y: int, m: int) -> list[date]:
    if m == 12:
        end = date(y + 1, 1, 1) - timedelta(days=1)
    else:
        end = date(y, m + 1, 1) - timedelta(days=1)
    start = date(y, m, 1)
    out: list[date] = []
    d = start
    while d <= end:
        out.append(d)
        d += timedelta(days=1)
    return out


def seed(
    conn,
    *,
    seed_march: int,
    seed_april: int,
) -> dict[str, int | str]:
    rng_m = random.Random(seed_march)
    rng_a = random.Random(seed_april)

    mar_days = _month_days(YEAR, 3)
    apr_days = _month_days(YEAR, 4)

    start_del = f"{YEAR}-03-01T00:00:00.000Z"
    end_del = f"{YEAR}-05-01T00:00:00.000Z"

    cur = conn.execute(
        """
        DELETE FROM account_daily_performance
        WHERE account_id = ? AND day >= ? AND day < ?
        """,
        (ACCOUNT_ID, f"{YEAR}-03-01", f"{YEAR}-05-01"),
    )
    deleted_adp = int(cur.rowcount)

    conn.execute(
        """
        DELETE FROM account_balance_snapshots
        WHERE account_id = ? AND snapshot_at >= ? AND snapshot_at < ?
        """,
        (ACCOUNT_ID, start_del, end_del),
    )

    for ym in (f"{YEAR}-03", f"{YEAR}-04"):
        conn.execute(
            """
            DELETE FROM account_month_balance_baseline
            WHERE account_id = ? AND year_month = ?
            """,
            (ACCOUNT_ID, ym),
        )

    rec = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

    def _upsert_baseline(ym: str, init_eq: float, init_bal: float) -> None:
        if IS_POSTGRES:
            conn.execute(
                """
                INSERT INTO account_month_balance_baseline
                  (account_id, year_month, initial_equity, initial_balance,
                   recorded_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (account_id, year_month) DO UPDATE SET
                  initial_equity = EXCLUDED.initial_equity,
                  initial_balance = EXCLUDED.initial_balance,
                  recorded_at = EXCLUDED.recorded_at
                """,
                (ACCOUNT_ID, ym, init_eq, init_bal, rec),
            )
        else:
            conn.execute(
                """
                INSERT OR REPLACE INTO account_month_balance_baseline
                  (account_id, year_month, initial_equity, initial_balance,
                   recorded_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (ACCOUNT_ID, ym, init_eq, init_bal, rec),
            )

    _upsert_baseline(f"{YEAR}-03", MAR_BASE, MAR_BASE)
    _upsert_baseline(f"{YEAR}-04", APR_BASE, APR_BASE)

    now_s = rec
    n_adp = 0
    n_sn = 0

    meta = db.account_list_get(ACCOUNT_ID)
    initial_cap = float(meta["initial_capital"]) if meta else 0.0

    cash = MAR_BASE
    eq = MAR_BASE

    def _insert_day(
        d: date,
        month_denom: float,
        rng: random.Random,
    ) -> None:
        nonlocal cash, eq, n_adp, n_sn
        bch = float(30 + rng.randint(1, 10))
        ech = float(5 + rng.randint(-10, 10))
        cash += bch
        eq += ech
        bcp = (bch / month_denom * 100.0) if month_denom > 1e-18 else None

        conn.execute(
            """
            INSERT INTO account_daily_performance
              (account_id, day, net_realized_pnl, close_pos_count,
               equlity_changed, balance_changed, balance_changed_pct, pnl_pct,
               instrument_id, market_truevolatility, efficiency_ratio,
               updated_at)
            VALUES (?, ?, 0, 0, ?, ?, ?, ?, ?, NULL, NULL, ?)
            """,
            (
                ACCOUNT_ID,
                d.isoformat(),
                ech,
                bch,
                bcp,
                0.0,
                INSTRUMENT_ID,
                now_s,
            ),
        )
        n_adp += 1

        avail = cash
        used = max(0.0, eq - cash)
        eq_profit_amt = eq - initial_cap
        eq_profit_pct = (
            (eq_profit_amt / initial_cap * 100.0)
            if abs(initial_cap) > 1e-18
            else 0.0
        )
        bal_profit_amt = cash - initial_cap
        bal_profit_pct = (
            (bal_profit_amt / initial_cap * 100.0)
            if abs(initial_cap) > 1e-18
            else 0.0
        )

        conn.execute(
            """
            INSERT INTO account_balance_snapshots
              (account_id, snapshot_at, cash_balance, available_margin,
               used_margin, equity_usdt,
               equity_profit_amount, equity_profit_percent,
               balance_profit_amount, balance_profit_percent)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                ACCOUNT_ID,
                _snapshot_ts(d),
                cash,
                avail,
                used,
                eq,
                eq_profit_amt,
                eq_profit_pct,
                bal_profit_amt,
                bal_profit_pct,
            ),
        )
        n_sn += 1

    for d in mar_days:
        _insert_day(d, MAR_BASE, rng_m)

    cash = APR_BASE
    eq = APR_BASE
    for d in apr_days:
        _insert_day(d, APR_BASE, rng_a)

    return {
        "random_seed_march": seed_march,
        "random_seed_april": seed_april,
        "account_daily_performance_deleted": deleted_adp,
        "account_daily_performance_inserted": n_adp,
        "account_balance_snapshots_inserted": n_sn,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="写入 Alang_Sandbox 2026-03/04 演示数据（仅该 account_id）",
    )
    parser.add_argument(
        "--seed-march",
        type=int,
        default=0,
        help="3 月日随机序列种子（默认 0 表示自动生成）",
    )
    parser.add_argument(
        "--seed-april",
        type=int,
        default=0,
        help="4 月日随机序列种子（默认 0 表示自动生成）",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="只打印随机种子与区间，不写库",
    )
    args = parser.parse_args()

    seed_m = args.seed_march if args.seed_march > 0 else random.randint(1, 2**31 - 1)
    seed_a = args.seed_april if args.seed_april > 0 else random.randint(1, 2**31 - 1)

    msg_seed = f"随机数（3月/4月日序列种子）: {seed_m} , {seed_a}"
    print(msg_seed)

    if args.dry_run:
        dr = (
            f"[dry-run] account_id={ACCOUNT_ID} "
            f"{YEAR}-03-01..{YEAR}-04-30 基准: 3月={MAR_BASE} 4月={APR_BASE}"
        )
        print(dr)
        return 0

    db.init_db()
    conn = db.get_conn()
    if not IS_POSTGRES:
        conn.execute("PRAGMA busy_timeout = 60000")
    try:
        out = seed(conn, seed_march=seed_m, seed_april=seed_a)
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
