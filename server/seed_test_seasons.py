# -*- coding: utf-8 -*-
"""为 2 个 bot 构造赛季测试数据：每月 4 个赛季，含启动时间、停止时间、起始金额、盈利、盈利率。可重复执行（会先清空该 2 个 bot 的旧赛季再插入）。"""
from __future__ import annotations

import random
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

import db

BOT_IDS = ["simpleserver-lhg", "simpleserver-hztech"]
SEASONS_PER_MONTH = 4
INITIAL_BALANCE_BASE = 5000.0  # 每个赛季起始金额围绕该值
# 每个赛季约 7～8 天，盈利范围（USD）
PROFIT_MIN = -200
PROFIT_MAX = 400


def _generate_month_seasons(bot_id: str) -> list[tuple]:
    """生成一个 bot 当月 4 个赛季：started_at, stopped_at, initial_balance, final_balance, profit_amount, profit_percent。"""
    now = datetime.now(timezone.utc)
    # 过去 30 天均分 4 个赛季（每赛季约 7～8 天），保证 started_at < stopped_at <= now
    period_start = now - timedelta(days=30)
    out = []
    for i in range(SEASONS_PER_MONTH):
        start_d = i * 8
        end_d = start_d + 7
        started_at = period_start + timedelta(days=start_d)
        stopped_at = period_start + timedelta(days=end_d, seconds=-1)
        if stopped_at > now:
            stopped_at = now
        if started_at >= stopped_at:
            stopped_at = started_at + timedelta(days=1)  # 至少 1 天
        initial = round(INITIAL_BALANCE_BASE + random.uniform(-100, 100), 2)
        profit_amount = round(random.uniform(PROFIT_MIN, PROFIT_MAX), 2)
        final_balance = round(initial + profit_amount, 2)
        profit_percent = round((profit_amount / initial * 100.0), 4) if initial else 0.0
        out.append((
            bot_id,
            started_at.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            stopped_at.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            initial,
            final_balance,
            profit_amount,
            profit_percent,
        ))
    return out


def seed():
    db.init_db()
    conn = db.get_conn()
    try:
        for bot_id in BOT_IDS:
            conn.execute("DELETE FROM bot_seasons WHERE bot_id = ?", (bot_id,))
        conn.commit()

        for bot_id in BOT_IDS:
            rows = _generate_month_seasons(bot_id)
            for r in rows:
                conn.execute(
                    """INSERT INTO bot_seasons
                       (bot_id, started_at, stopped_at, initial_balance, final_balance, profit_amount, profit_percent)
                       VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    r,
                )
        conn.commit()
        print(f"已写入 {len(BOT_IDS)} 个 bot、各 {SEASONS_PER_MONTH} 条赛季，起始金额约 {INITIAL_BALANCE_BASE} USD。")
    finally:
        conn.close()


if __name__ == "__main__":
    seed()
