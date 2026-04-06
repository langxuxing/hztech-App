# -*- coding: utf-8 -*-
"""历史仓位 API：入库数据经 GET /position-history 读出（与 QTrader-web 按日汇总思路一致，本库为 SQLite）。"""
from __future__ import annotations

import db


def test_position_history_reads_inserted_rows(client, auth_headers):
    aid = "simpleserver-lhg"
    synced = "2026-04-01T00:00:00.000000Z"
    okx_row = {
        "posId": "pytest-pos-history-1",
        "uTime": "2000000000001",
        "instId": "TEST-USDT-SWAP",
        "instType": "SWAP",
        "posSide": "long",
        "pnl": "12.3",
        "fee": "-0.5",
        "fundingFee": "0",
    }
    inserted = db.account_positions_history_insert_batch(aid, [okx_row], synced)
    assert inserted == 1

    r = client.get(
        f"/api/tradingbots/{aid}/position-history?limit=20",
        headers=auth_headers,
    )
    assert r.status_code == 200
    data = r.get_json()
    assert data.get("success") is True
    rows = data.get("rows") or []
    assert any(str(x.get("okx_pos_id")) == "pytest-pos-history-1" for x in rows)


def test_position_history_before_utime_pagination(client, auth_headers):
    aid = "simpleserver-hztech"
    synced = "2026-04-01T00:00:00.000000Z"
    db.account_positions_history_insert_batch(
        aid,
        [
            {
                "posId": "pytest-ph-page-a",
                "uTime": "2000000000100",
                "instId": "A-USDT-SWAP",
            },
            {
                "posId": "pytest-ph-page-b",
                "uTime": "2000000000050",
                "instId": "B-USDT-SWAP",
            },
        ],
        synced,
    )
    first = client.get(
        f"/api/tradingbots/{aid}/position-history?limit=1",
        headers=auth_headers,
    )
    assert first.status_code == 200
    d1 = first.get_json()
    assert d1.get("success") and d1.get("rows")
    assert d1["rows"][0]["okx_pos_id"] == "pytest-ph-page-a"
    nb = d1.get("next_before_utime")
    assert nb == 2000000000100

    second = client.get(
        f"/api/tradingbots/{aid}/position-history?limit=1&before_utime={nb}",
        headers=auth_headers,
    )
    assert second.status_code == 200
    d2 = second.get_json()
    assert d2.get("rows") and d2["rows"][0]["okx_pos_id"] == "pytest-ph-page-b"
