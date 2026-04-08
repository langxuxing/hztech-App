# -*- coding: utf-8 -*-
"""account_positions_history 表批量写入与去重。"""
from __future__ import annotations

import db


def _clear_aph(aid: str) -> None:
    """PostgreSQL 等持久化测试库上避免与上次运行残留冲突。"""
    conn = db.get_conn()
    try:
        conn.execute(
            "DELETE FROM account_positions_history WHERE account_id = ?",
            (aid,),
        )
        conn.commit()
    finally:
        conn.close()


def test_positions_history_insert_dedup():
    _clear_aph("acct-a")
    ts = "2026-04-03T12:00:00.000000Z"
    row = {
        "posId": "452587086133239818",
        "uTime": "1654177174419",
        "cTime": "1654177169995",
        "instId": "BTC-USDT-SWAP",
        "instType": "SWAP",
        "posSide": "long",
        "mgnMode": "cross",
        "openAvgPx": "29783.9",
        "closeAvgPx": "29786.6",
        "openMaxPos": "1",
        "closeTotalPos": "1",
        "pnl": "0.0011",
        "realizedPnl": "0.001",
        "fee": "-0.0001",
        "fundingFee": "0",
        "type": "1",
        "lever": "50",
    }
    n1 = db.account_positions_history_insert_batch("acct-a", [row], ts)
    n2 = db.account_positions_history_insert_batch("acct-a", [row], ts)
    assert n1 == 1
    assert n2 == 0
    q = db.account_positions_history_query_by_account("acct-a", limit=10)
    assert len(q) == 1
    assert q[0]["okx_pos_id"] == "452587086133239818"
    assert q[0]["u_time_ms"] == "1654177174419"
    assert q[0].get("lever") == "50"


def test_positions_history_max_u_time_ms():
    aid = "acct-max-ut"
    _clear_aph(aid)
    ts = "2026-04-03T12:00:00.000000Z"
    rows = [
        {
            "posId": "111",
            "uTime": "1000",
            "cTime": "900",
            "instId": "BTC-USDT-SWAP",
            "instType": "SWAP",
            "posSide": "long",
            "mgnMode": "cross",
            "openAvgPx": "1",
            "closeAvgPx": "1",
            "openMaxPos": "1",
            "closeTotalPos": "1",
            "pnl": "0",
            "realizedPnl": "0",
            "fee": "0",
            "fundingFee": "0",
            "type": "1",
        },
        {
            "posId": "222",
            "uTime": "2000",
            "cTime": "1900",
            "instId": "BTC-USDT-SWAP",
            "instType": "SWAP",
            "posSide": "short",
            "mgnMode": "cross",
            "openAvgPx": "1",
            "closeAvgPx": "1",
            "openMaxPos": "1",
            "closeTotalPos": "1",
            "pnl": "0",
            "realizedPnl": "0",
            "fee": "0",
            "fundingFee": "0",
            "type": "1",
        },
    ]
    db.account_positions_history_insert_batch(aid, rows, ts)
    assert db.account_positions_history_max_u_time_ms(aid) == 2000
    assert db.account_positions_history_max_u_time_ms("nonexistent_xyz") is None
