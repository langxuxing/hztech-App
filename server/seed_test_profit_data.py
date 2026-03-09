# -*- coding: utf-8 -*-
"""为 2 个 bot 构造 1 个月、从 5000 USD 开始的 SQLite 测试数据。可重复执行（会先清空该 2 个 bot 的旧快照再插入）。"""
from __future__ import annotations

import random
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

# 保证能导入 db（从项目根或 server 目录运行均可）
SERVER_DIR = Path(__file__).resolve().parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

import db

# 与 tradingbots.json 一致的两个 bot
BOT_IDS = ["simpleserver-lhg", "simpleserver-hztech"]
INITIAL_BALANCE_USD = 5000.0
DAYS = 31  # 约 1 个月
# 每日权益变化范围（USD），略微随机使曲线更真实
DAILY_CHANGE_MIN = -80
DAILY_CHANGE_MAX = 120


def _generate_month_snapshots(bot_id: str) -> list[tuple]:
    """生成一个 bot 一个月内的快照数据（snapshot_at, initial_balance, current_balance, equity_usdt, profit_amount, profit_percent）。"""
    now = datetime.now(timezone.utc)
    out = []
    balance = INITIAL_BALANCE_USD
    for i in range(DAYS):
        snap_at = (now - timedelta(days=DAYS - 1 - i)).replace(hour=8, minute=0, second=0, microsecond=0)
        snapshot_at = snap_at.strftime("%Y-%m-%dT%H:%M:%S.000Z")
        # 第一天不变，之后每天加一点随机变化
        if i > 0:
            balance += random.uniform(DAILY_CHANGE_MIN, DAILY_CHANGE_MAX)
            balance = max(100.0, round(balance, 2))  # 避免负或过小
        profit_amount = round(balance - INITIAL_BALANCE_USD, 2)
        profit_percent = round((profit_amount / INITIAL_BALANCE_USD) * 100.0, 4) if INITIAL_BALANCE_USD else 0.0
        out.append((
            bot_id,
            snapshot_at,
            INITIAL_BALANCE_USD,
            round(balance, 2),
            round(balance, 2),
            profit_amount,
            profit_percent,
        ))
    return out


def seed():
    db.init_db()
    conn = db.get_conn()
    try:
        for bot_id in BOT_IDS:
            conn.execute("DELETE FROM bot_profit_snapshots WHERE bot_id = ?", (bot_id,))
        conn.commit()

        for bot_id in BOT_IDS:
            rows = _generate_month_snapshots(bot_id)
            for r in rows:
                conn.execute(
                    """INSERT INTO bot_profit_snapshots
                       (bot_id, snapshot_at, initial_balance, current_balance, equity_usdt, profit_amount, profit_percent)
                       VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    r,
                )
        conn.commit()
        print(f"已写入 {len(BOT_IDS)} 个 bot、各 {DAYS} 条快照，初始金额 {INITIAL_BALANCE_USD} USD。")
    finally:
        conn.close()


if __name__ == "__main__":
    seed()
