#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PostgreSQL / 通用库：管理员手工数据补全入口（当前实现：OKX bills-archive 补余额快照缺日）。

定时任务 ``refresh_all_balance_snapshots`` 不再自动执行 bills 补全；请使用：

- ``POST /api/admin/balance-snapshots/backfill-bills``（须管理员 JWT），或
- 本脚本（在 ``baasapi`` 目录下，与 ``purge_account_history.py`` 相同的数据库环境变量），或
- 运维：仓库根目录 ``./aws-ops/code/balance_snapshots_bills_backfill.sh``（SSH 至 BaasAPI 主机后执行本脚本）。

示例::

    cd baasapi
    python pg_data_fill.py
    python pg_data_fill.py --days 60 --account HzTech_MainRepo
"""
from __future__ import annotations

import argparse
import logging
import sys
from typing import Any


def run_okx_bills_balance_snapshot_backfill(
    db_module: Any,
    account_mgr_module: Any,
    logger: logging.Logger,
    *,
    days: int = 40,
    account_id: str | None = None,
) -> dict[str, Any]:
    """对启用账户或单个 account_id：OKX bills-archive 补 account_balance_snapshots 缺日。

    与 main 中管理员 backfill-bills 接口一致；有插入时刷新北京「当天」
    account_daily_performance 临时行。
    """
    days_i = max(7, min(92, int(days)))
    total = 0
    details: list[dict[str, Any]] = []
    accounts_adp: list[str] = []

    aid_one = (account_id or "").strip()
    if aid_one:
        account_rows = [{"account_id": aid_one}]
    else:
        account_rows = [
            {"account_id": str(b.get("account_id") or "").strip()}
            for b in account_mgr_module.list_account_basics(enabled_only=True)
            if str(b.get("account_id") or "").strip()
        ]

    for row in account_rows:
        aid = str(row.get("account_id") or "").strip()
        if not aid:
            continue
        try:
            n, msg = account_mgr_module.backfill_account_snapshots_from_okx_bills(
                db_module,
                aid,
                logger,
                days=days_i,
            )
        except Exception as e:
            details.append(
                {"account_id": aid, "inserted": 0, "message": str(e)}
            )
            continue
        total += n
        if n > 0:
            accounts_adp.append(aid)
        if n or msg:
            details.append({"account_id": aid, "inserted": n, "message": msg})

    if accounts_adp:
        refresh_adp = (
            account_mgr_module.refresh_account_daily_performance_today_provisional_safe
        )
        refresh_adp(db_module, accounts_adp, logger)

    return {
        "success": True,
        "total_inserted": total,
        "accounts": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "OKX bills-archive → account_balance_snapshots 缺日补全（管理员手工）"
        )
    )
    parser.add_argument(
        "--days",
        type=int,
        default=40,
        help="回看 UTC 自然日数，7～92，默认 40",
    )
    parser.add_argument(
        "--account",
        type=str,
        default="",
        help="仅处理该 account_id；省略则处理 Account_List 全部启用账户",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(message)s",
    )
    log = logging.getLogger("pg_data_fill")

    import db as db_mod
    from accounts import AccountMgr as am

    out = run_okx_bills_balance_snapshot_backfill(
        db_mod,
        am,
        log,
        days=args.days,
        account_id=args.account.strip() or None,
    )
    acct_rows = out.get("accounts") or []
    print(
        "total_inserted=%s accounts=%s"
        % (out["total_inserted"], len(acct_rows))
    )
    for row in acct_rows:
        msg = row.get("message") or ""
        print(
            "  %s: inserted=%s %s"
            % (row.get("account_id"), row.get("inserted"), msg)
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
