#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 account_positions_history 按北京时间日历日汇总平仓净盈亏，重建 account_daily_performance（全账户；
不设 equity_base 列；pnl_pct 分母为当月 account_month_balance_baseline 口径，与链式列一致）。

用法（在 baasapi 目录下或设置 PYTHONPATH）：
  python -m baasapi.rebuild_account_daily_performance

或：
  cd baasapi && python rebuild_account_daily_performance.py
"""
from __future__ import annotations

import os
import sys

_server_dir = os.path.dirname(os.path.abspath(__file__))
if _server_dir not in sys.path:
    sys.path.insert(0, _server_dir)

import db  # noqa: E402
from accounts.AccountMgr import _account_benchmark_inst_map  # noqa: E402


def main() -> None:
    db.init_db()
    ids = db.account_ids_for_daily_performance_rebuild()
    if not ids:
        print(
            "无账户 id（account_list 与 account_positions_history 均为空），退出。"
        )
        return
    db.account_daily_performance_rebuild_for_accounts(ids, _account_benchmark_inst_map())
    print(f"已重建 account_daily_performance，共 {len(ids)} 个账户。")


if __name__ == "__main__":
    main()
