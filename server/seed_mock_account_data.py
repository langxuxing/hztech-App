#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为 Account_List 中的 OKX 账户写入模拟数据（account_list、account_balance_snapshots、
account_month_open）。

默认：仅当该账户在 account_balance_snapshots 中尚无任何记录时写入。
时间：自 2026-01-01（UTC）起至「今天」每日一条快照。
初始资金：默认 5000 USDT（可用 --initial 修改）。
收益：总收益率随机落在 15%–20% 之间；逐日围绕趋势线叠加约 ±1%–2% 波动（回测噪声）。

用法（在 server 目录下）:
  python seed_mock_account_data.py
  python seed_mock_account_data.py --force
  python seed_mock_account_data.py --initial 5000 --end-date 2026-04-03
"""
from __future__ import annotations

import argparse
import random
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

# server 为工作目录
SERVER_DIR = Path(__file__).resolve().parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

import db  # noqa: E402
from accounts import AccountMgr  # noqa: E402


def _parse_date(s: str) -> date:
    y, m, d = (int(x) for x in s.strip().split("-")[:3])
    return date(y, m, d)


def _day_iter(start: date, end: date):
    d = start
    while d <= end:
        yield d
        d += timedelta(days=1)


def _build_equity_series(
    *,
    initial: float,
    n_days: int,
    total_return: float,
    rng: random.Random,
) -> list[float]:
    """n_days 个权益点，首末接近 initial 与 initial*(1+total_return)，中间带 1–2% 噪声。"""
    if n_days <= 0:
        return []
    final_target = initial * (1.0 + total_return)
    if n_days == 1:
        return [final_target]

    out: list[float] = []
    for i in range(n_days):
        t = i / (n_days - 1)
        trend = initial + (final_target - initial) * t
        if i == 0:
            eq = initial * rng.uniform(0.995, 1.005)
        elif i == n_days - 1:
            eq = final_target
        else:
            # 约 ±1%–2% 波动
            eq = trend * rng.uniform(0.98, 1.02)
        eq = max(eq, initial * 0.85)
        out.append(eq)
    out[-1] = final_target
    return out


def _snapshot_ts(day: date, hour: int = 8) -> str:
    dt = datetime(
        day.year, day.month, day.day, hour, 0, 0, tzinfo=timezone.utc
    )
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def seed_one_account(
    conn,
    account_id: str,
    *,
    initial: float,
    start: date,
    end: date,
    rng: random.Random,
) -> int:
    """写入一个账户的快照与月初记录，返回插入行数。"""
    days = list(_day_iter(start, end))
    n = len(days)
    total_return = rng.uniform(0.15, 0.20)
    equities = _build_equity_series(
        initial=initial,
        n_days=n,
        total_return=total_return,
        rng=rng,
    )
    rows = 0
    month_first: dict[str, tuple[float, float, str]] = {}

    for day, eq in zip(days, equities):
        ts = _snapshot_ts(day)
        profit = eq - initial
        pct = (profit / initial * 100.0) if initial else 0.0
        cash_bal = eq * rng.uniform(0.93, 0.99)
        cash_profit = cash_bal - initial
        cash_pct = (cash_profit / initial * 100.0) if initial else 0.0
        avail_eq = cash_bal * rng.uniform(0.90, 0.98)
        used_m = max(0.0, eq - avail_eq)
        conn.execute(
            """INSERT INTO account_balance_snapshots
               (account_id, snapshot_at, cash_balance, available_margin, used_margin, equity_usdt,
                profit_amount, profit_percent, cash_profit_amount, cash_profit_percent)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                account_id,
                ts,
                cash_bal,
                avail_eq,
                used_m,
                eq,
                profit,
                pct,
                cash_profit,
                cash_pct,
            ),
        )
        rows += 1
        ym = f"{day.year:04d}-{day.month:02d}"
        if ym not in month_first:
            month_first[ym] = (eq, cash_bal, ts)

    for ym, (open_eq, open_cash, rec_at) in sorted(month_first.items()):
        conn.execute(
            """INSERT OR REPLACE INTO account_month_open
               (account_id, year_month, open_equity, open_cash, recorded_at)
               VALUES (?, ?, ?, ?, ?)""",
            (account_id, ym, open_eq, open_cash, rec_at),
        )

    conn.execute(
        """INSERT INTO account_list (
               account_id, account_name, exchange_account, symbol, initial_capital,
               trading_strategy, account_key_file, script_file, enabled, updated_at)
           VALUES (?, '', '', '', ?, '', '', '', 1, datetime('now'))
           ON CONFLICT(account_id) DO UPDATE SET
             initial_capital = excluded.initial_capital,
             updated_at = datetime('now')""",
        (account_id, initial),
    )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="写入账户 SQLite 模拟快照数据")
    parser.add_argument(
        "--initial",
        type=float,
        default=5000.0,
        help="初始资金（默认 5000）",
    )
    parser.add_argument(
        "--start-date",
        type=str,
        default="2026-01-01",
        help="起始日期 YYYY-MM-DD（默认 2026-01-01）",
    )
    parser.add_argument(
        "--end-date",
        type=str,
        default="",
        help="结束日期 YYYY-MM-DD（默认今天 UTC）",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="即使已有快照也删除并重建",
    )
    parser.add_argument(
        "--only",
        type=str,
        default="",
        help="仅处理该 account_id",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="随机种子（默认可复现：按 account_id 哈希）",
    )
    args = parser.parse_args()

    db.init_db()
    start = _parse_date(args.start_date)
    if args.end_date.strip():
        end = _parse_date(args.end_date)
    else:
        end = datetime.now(timezone.utc).date()
    if end < start:
        print("end-date 必须 >= start-date", file=sys.stderr)
        return 2

    basics = AccountMgr.list_account_basics(enabled_only=False)
    if args.only.strip():
        want = args.only.strip()
        basics = [b for b in basics if b["account_id"] == want]
        if not basics:
            print(f"未找到 account_id={want}", file=sys.stderr)
            return 2

    conn = db.get_conn()
    try:
        total = 0
        for b in basics:
            aid = b["account_id"]
            cur = conn.execute(
                "SELECT COUNT(*) FROM account_balance_snapshots WHERE account_id = ?",
                (aid,),
            )
            existing = cur.fetchone()[0]
            if existing > 0 and not args.force:
                msg = f"跳过 {aid}（已有 {existing} 条快照，使用 --force 覆盖）"
                print(msg)
                continue
            if existing > 0 and args.force:
                conn.execute(
                    "DELETE FROM account_balance_snapshots WHERE account_id = ?",
                    (aid,),
                )
                conn.execute(
                    "DELETE FROM account_month_open WHERE account_id = ?",
                    (aid,),
                )

            seed_val = args.seed
            if seed_val is None:
                seed_val = hash(aid) % (2**31)
            rng = random.Random(seed_val)
            n = seed_one_account(
                conn,
                aid,
                initial=float(args.initial),
                start=start,
                end=end,
                rng=rng,
            )
            conn.commit()
            total += n
            print(f"已写入 {aid}: {n} 条快照，初始 {args.initial}，区间 {start} ~ {end}")
        print(f"完成，共插入 {total} 条 account_balance_snapshots 行。")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
