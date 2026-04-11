# -*- coding: utf-8 -*-
"""account_daily_performance 重建与查询。"""
from __future__ import annotations

import db


def test_daily_performance_rebuild_equity_and_efficiency():
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
        "realizedPnl": "99",
        "fee": "-1",
        "fundingFee": "0",
        "type": "1",
    }
    db.account_list_upsert(aid, 5000.0)
    db.account_snapshot_insert(
        aid,
        "2026-04-04T10:00:00.000000Z",
        4000.0,
        4000.0,
        -1000.0,
        -20.0,
        available_margin=4000.0,
        used_margin=0.0,
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
    db.account_month_balance_baseline_upsert(
        aid,
        "2026-04",
        4000.0,
        "2026-04-01T00:00:00.000000Z",
        initial_balance=4000.0,
    )
    # 落在北京时间 2026-04-05 内的 UTC 时刻（非 23:59 UTC，否则已是北京 4/6）
    db.account_snapshot_insert(
        aid,
        "2026-04-05T12:00:00.000000Z",
        4000.0,
        4099.0,
        -901.0,
        -18.02,
        available_margin=4000.0,
        used_margin=0.0,
    )

    db.account_daily_performance_rebuild_for_accounts(
        [aid], {aid: "PEPE-USDT-SWAP"}
    )

    q = db.account_daily_performance_query_month(aid, 2026, 4)
    r = next(x for x in q if x["day"] == "2026-04-05")
    assert abs(r["net_pnl"] - 99.0) < 1e-6
    assert r["close_pos_count"] == 1
    assert r["equlity_changed"] is not None and abs(r["equlity_changed"] - 99.0) < 1e-6
    assert r["balance_changed"] is not None and abs(r["balance_changed"]) < 1e-9
    assert r["balance_changed_pct"] is not None and abs(r["balance_changed_pct"]) < 1e-9
    exp_pct = 99.0 / 4000.0 * 100.0
    assert r["pnl_pct"] is not None and abs(r["pnl_pct"] - exp_pct) < 1e-6
    assert r["instrument_id"] == "PEPE-USDT-SWAP"
    assert r["market_truevolatility"] == 0.2
    assert r["efficiency_ratio"] is not None
    assert abs(r["efficiency_ratio"] - 99.0 / (0.2 * 1e9)) < 1e-12
    assert r.get("equity_changed_pct") is None


def test_daily_performance_sparse_snapshot_pnl_pct_fixed_month_denom():
    """连续两日 pnl_pct 分母均为当月 account_month_balance_baseline 口径（initial_balance 优先）。"""
    aid = "acct-perf-chain-2"
    ts1 = "2026-04-05T12:00:00.000000Z"
    ts2 = "2026-04-06T12:00:00.000000Z"
    day1_ms = "1775347200000"
    day2_ms = "1775433600000"
    row1 = {
        "posId": "452587086133239901",
        "uTime": day1_ms,
        "cTime": day1_ms,
        "instId": "BTC-USDT-SWAP",
        "instType": "SWAP",
        "posSide": "long",
        "mgnMode": "cross",
        "openAvgPx": "29783.9",
        "closeAvgPx": "29786.6",
        "openMaxPos": "1",
        "closeTotalPos": "1",
        "pnl": "100",
        "realizedPnl": "99",
        "fee": "-1",
        "fundingFee": "0",
        "type": "1",
    }
    row2 = {
        "posId": "452587086133239902",
        "uTime": day2_ms,
        "cTime": day2_ms,
        "instId": "BTC-USDT-SWAP",
        "instType": "SWAP",
        "posSide": "long",
        "mgnMode": "cross",
        "openAvgPx": "29783.9",
        "closeAvgPx": "29786.6",
        "openMaxPos": "1",
        "closeTotalPos": "1",
        "pnl": "200",
        "realizedPnl": "198",
        "fee": "-2",
        "fundingFee": "0",
        "type": "1",
    }
    db.account_list_upsert(aid, 5000.0)
    db.account_snapshot_insert(
        aid,
        "2026-04-04T10:00:00.000000Z",
        4000.0,
        4000.0,
        -1000.0,
        -20.0,
        available_margin=4000.0,
        used_margin=0.0,
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
    db.market_daily_bars_upsert(
        "PEPE-USDT-SWAP",
        "2026-04-06",
        1.0,
        1.1,
        0.9,
        1.05,
        0.25,
    )
    db.account_positions_history_insert_batch(aid, [row1], ts1)
    db.account_positions_history_insert_batch(aid, [row2], ts2)
    db.account_month_balance_baseline_upsert(
        aid,
        "2026-04",
        4000.0,
        "2026-04-01T00:00:00.000000Z",
        initial_balance=4000.0,
    )

    db.account_daily_performance_rebuild_for_accounts(
        [aid], {aid: "PEPE-USDT-SWAP"}
    )

    q = db.account_daily_performance_query_month(aid, 2026, 4)
    d5 = next(x for x in q if x["day"] == "2026-04-05")
    d6 = next(x for x in q if x["day"] == "2026-04-06")
    net5 = 99.0
    net6 = 198.0
    assert abs(d5["net_pnl"] - net5) < 1e-6
    assert abs(d6["net_pnl"] - net6) < 1e-6
    assert d5["pnl_pct"] is not None and abs(d5["pnl_pct"] - net5 / 4000.0 * 100.0) < 1e-6
    assert d6["pnl_pct"] is not None and abs(d6["pnl_pct"] - net6 / 4000.0 * 100.0) < 1e-6


def test_daily_performance_provisional_refresh_today_upsert():
    """当日临时刷写：头尾快照差 + 平仓聚合，UPSERT 不删其它日。"""
    aid = "acct-perf-prov-1"
    bench = {aid: "PEPE-USDT-SWAP"}
    db.account_list_upsert(aid, 10_000.0)
    db.account_month_balance_baseline_upsert(
        aid,
        "2026-04",
        5000.0,
        "2026-04-01T00:00:00.000000Z",
        initial_balance=4000.0,
    )
    # 北京 2026-04-10 日界：前一日界前一条 + 日内两条（避免跨北京日界的 UTC 时刻误算）
    db.account_snapshot_insert(
        aid,
        "2026-04-09T15:00:00.000000Z",
        5000.0,
        4000.0,
        0.0,
        0.0,
        available_margin=4000.0,
        used_margin=0.0,
    )
    db.account_snapshot_insert(
        aid,
        "2026-04-10T02:00:00.000000Z",
        5000.0,
        4000.0,
        0.0,
        0.0,
        available_margin=4000.0,
        used_margin=0.0,
    )
    db.account_snapshot_insert(
        aid,
        "2026-04-10T10:00:00.000000Z",
        5100.0,
        4400.0,
        0.0,
        0.0,
        available_margin=4400.0,
        used_margin=0.0,
    )
    db.market_daily_bars_upsert(
        "PEPE-USDT-SWAP",
        "2026-04-10",
        1.0,
        1.1,
        0.9,
        1.05,
        0.2,
    )
    day_ms = "1775793600000"
    row = {
        "posId": "452587086133239903",
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
        "pnl": "50",
        "realizedPnl": "50",
        "fee": "0",
        "fundingFee": "0",
        "type": "1",
    }
    ts = "2026-04-10T12:00:00.000000Z"
    db.account_positions_history_insert_batch(aid, [row], ts)

    db.account_daily_performance_refresh_today_provisional_for_accounts(
        [aid], "2026-04-10", bench
    )

    q = db.account_daily_performance_query_month(aid, 2026, 4)
    r = next(x for x in q if x["day"] == "2026-04-10")
    assert abs(r["net_pnl"] - 50.0) < 1e-6
    assert r["close_pos_count"] == 1
    assert r["balance_changed"] is not None and abs(r["balance_changed"] - 400.0) < 1e-6
    assert r["balance_changed_pct"] is not None and abs(r["balance_changed_pct"] - 10.0) < 1e-6
    assert r["equlity_changed"] is not None and abs(r["equlity_changed"] - 100.0) < 1e-6
    assert r["equity_changed_pct"] is not None and abs(r["equity_changed_pct"] - 2.0) < 1e-6
    exp_pnl_pct = 50.0 / 4000.0 * 100.0
    assert r["pnl_pct"] is not None and abs(r["pnl_pct"] - exp_pnl_pct) < 1e-6
