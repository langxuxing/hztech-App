# -*- coding: utf-8 -*-
"""account_open_positions_snapshots 表插入与查询。"""
from __future__ import annotations

import db
from accounts.AccountMgr import aggregate_open_positions_by_inst


def test_open_positions_snapshots_insert_and_query():
    ts = "2026-04-06T12:00:00.000000Z"
    aid = "acc-open-snap-test"
    n = db.account_open_positions_snapshots_insert_batch(
        aid,
        ts,
        [
            {
                "inst_id": "PEPE-USDT-SWAP",
                "last_px": 1.5,
                "long_pos_size": 100.0,
                "short_pos_size": 0.0,
                "mark_px": 1.48,
                "long_upl": -2.5,
                "short_upl": 0.0,
                "total_upl": -2.5,
                "open_leg_count": 1,
            }
        ],
    )
    assert n == 1
    rows = db.account_open_positions_snapshots_query_by_account(aid, limit=10)
    assert len(rows) >= 1
    hit = next((r for r in rows if r["snapshot_at"] == ts), None)
    assert hit is not None
    assert hit["inst_id"] == "PEPE-USDT-SWAP"
    assert abs(hit["long_upl"] - (-2.5)) < 1e-9
    assert int(hit.get("open_leg_count") or 0) == 1
    r2 = db.account_open_positions_snapshots_query_by_account(
        aid, limit=10, inst_id="PEPE-USDT-SWAP"
    )
    assert any(r["snapshot_at"] == ts for r in r2)


def test_aggregate_open_positions_by_inst_long_short():
    agg = aggregate_open_positions_by_inst(
        [
            {
                "inst_id": "BTC-USDT-SWAP",
                "pos_side": "long",
                "pos": 3.0,
                "upl": 1.0,
                "mark_px": 100.0,
                "last_px": 101.0,
                "avg_px": 99.0,
                "liq_px": 90.0,
            },
            {
                "inst_id": "BTC-USDT-SWAP",
                "pos_side": "short",
                "pos": -2.0,
                "upl": -0.5,
                "mark_px": 100.0,
                "last_px": 101.0,
                "avg_px": 102.0,
                "liq_px": 110.0,
            },
        ]
    )
    assert len(agg) == 1
    g = agg[0]
    assert g["long_pos_size"] == 3.0
    assert g["short_pos_size"] == 2.0
    assert abs(g["total_upl"] - 0.5) < 1e-9
    assert abs(g["long_upl"] - 1.0) < 1e-9
    assert abs(g["short_upl"] - (-0.5)) < 1e-9
    assert g.get("open_leg_count") == 2
    assert abs(g.get("long_liq_px", 0) - 90.0) < 1e-9
    assert abs(g.get("short_liq_px", 0) - 110.0) < 1e-9
