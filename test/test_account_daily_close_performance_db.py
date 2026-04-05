# -*- coding: utf-8 -*-
"""account_daily_close_performance 重建与查询。"""
from __future__ import annotations

import db


def test_close_performance_rebuild_equity_and_efficiency():
    aid = "acct-perf-1"
    ts = "2026-04-05T12:00:00.000000Z"
    day_ms = "1775347200000"
    row = {
        "posId": "452587086133239900",
        "uTime": day_ms,
        "cTime": day_ms,
        "instId": "BTC-USDT-SWAP",
        "instType": "SWAP",
        "posSide": "long",
        "mgnMode": "cross",
        "openAvgPx": "29783.9",
        "closeAvgPx": "29786.6",
        "openMaxPos": "1",
        "closeTotalPos": "1",
        "pnl": "100",
        "realizedPnl": "100",
        "fee": "-1",
        "fundingFee": "0",
        "type": "1",
    }
    db.account_meta_upsert(aid, 5000.0)
    db.account_snapshot_insert(
        aid,
        "2026-04-04T10:00:00.000000Z",
        4000.0,
        4000.0,
        5000.0,
        -1000.0,
        -20.0,
    )
    db.market_daily_bars_upsert(
        "PEPE-USDT-SWAP",
        "2026-04-05",
        1.0,
        1.1,
        0.9,
        1.05,
        0.2,
    )
    db.account_positions_history_insert_batch(aid, [row], ts)

    db.account_daily_close_performance_rebuild_for_accounts(
        [aid], {aid: "PEPE-USDT-SWAP"}
    )

    q = db.account_daily_close_performance_query_month(aid, 2026, 4)
    assert len(q) == 1
    r = q[0]
    assert r["day"] == "2026-04-05"
    assert abs(r["net_pnl"] - 99.0) < 1e-6
    assert r["close_count"] == 1
    assert r["equity_base"] == 4000.0
    assert r["pnl_pct"] is not None and abs(r["pnl_pct"] - 99.0 / 4000.0 * 100.0) < 1e-6
    assert r["benchmark_inst_id"] == "PEPE-USDT-SWAP"
    assert r["market_tr"] == 0.2
    assert r["efficiency_ratio"] is not None
    assert abs(r["efficiency_ratio"] - 99.0 / (0.2 * 1e9)) < 1e-12
