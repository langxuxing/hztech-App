# -*- coding: utf-8 -*-
"""POST /api/accounts/<id>/trade/execute 鉴权与账户校验。"""
from __future__ import annotations

import sys

import pytest

_server_dir = __import__("os").path.join(
    __import__("os").path.dirname(__file__), "..", "baasapi"
)
sys.path.insert(0, __import__("os").path.abspath(_server_dir))


class TestAccountManualTradeApi:
    def test_trade_execute_forbidden_strategy_analyst(
        self, client, analyst_headers
    ):
        r = client.post(
            "/api/accounts/simpleserver/trade/execute",
            json={"op": "close_all"},
            headers=analyst_headers,
        )
        assert r.status_code == 403
        data = r.get_json()
        assert data.get("success") is False

    def test_trade_execute_unknown_account(self, client, auth_headers):
        r = client.post(
            "/api/accounts/__not_in_account_list_xyz__/trade/execute",
            json={"op": "close_all"},
            headers=auth_headers,
        )
        assert r.status_code == 400
        data = r.get_json()
        assert data.get("success") is False

    def test_trade_execute_mocked_ok(self, client, auth_headers, monkeypatch):
        import account_manual_trade as amt

        r0 = client.get("/api/accounts", headers=auth_headers)
        assert r0.status_code == 200
        bots = r0.get_json().get("bots") or []
        if not bots:
            pytest.skip("无交易账户")
        aid = str(bots[0].get("tradingbot_id") or "").strip()
        assert aid

        def fake_run(**kwargs):
            return (
                {
                    "success": True,
                    "message": "stub",
                    "bot_id": kwargs.get("account_id", ""),
                    "inst_id": "TEST-USDT-SWAP",
                    "steps": [{"name": "stub", "ok": True, "detail": ""}],
                    "warnings": [],
                },
                200,
            )

        monkeypatch.setattr(amt, "run_manual_trade_op", fake_run)

        r = client.post(
            f"/api/accounts/{aid}/trade/execute",
            json={"op": "close_all"},
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert data.get("message") == "stub"
