# -*- coding: utf-8 -*-
"""
模拟 Flutter App 登录与交易所账户相关请求链：登录 → account-profit → tradingbots →
按列表中的 account_id 拉持仓 / 收益历史 / 委托 / 行情（与 ApiClient 一致）。

与 AccountMgr 数据源的全量对齐见 test_main_accountmgr_e2e.py。
"""
from __future__ import annotations

import sys

import pytest

_server_dir = __import__("os").path.join(
    __import__("os").path.dirname(__file__), "..", "baasapi"
)
sys.path.insert(0, __import__("os").path.abspath(_server_dir))


def _first_okx_account_id(bots: list) -> str | None:
    for b in bots:
        tid = (b.get("tradingbot_id") or "").strip()
        if tid.startswith("OKX_"):
            return tid
    return None


class TestAppAccountFlowLikeFlutter:
    """与 flutterapp/lib/api/client.dart 中账户相关接口调用顺序一致。"""

    def test_login_then_account_apis_match_app_contract(self, client, auth_headers):
        # 1) account-profit（账户盈亏页）
        r = client.get("/api/account-profit", headers=auth_headers)
        assert r.status_code == 200
        profit = r.get_json()
        assert profit.get("success") is True
        assert "accounts" in profit
        assert isinstance(profit["accounts"], list)
        for a in profit["accounts"]:
            assert "bot_id" in a or a.get("account_id")
            assert "equity_usdt" in a or "current_balance" in a

        # 2) tradingbots（列表 / 下拉）
        r = client.get("/api/tradingbots", headers=auth_headers)
        assert r.status_code == 200
        tb = r.get_json()
        bots = tb.get("bots") or tb.get("tradingbots") or []
        assert isinstance(bots, list)
        assert tb.get("total") == len(bots)

        bot_id = _first_okx_account_id(bots)
        if bot_id is None:
            pytest.skip("当前 tradingbots 列表中无 Account_List 的 OKX_* 账户，跳过 per-account 接口")

        # 3) profit-history（收益曲线）
        r = client.get(
            f"/api/tradingbots/{bot_id}/profit-history?limit=50",
            headers=auth_headers,
        )
        assert r.status_code == 200
        hist = r.get_json()
        assert hist.get("success") is True
        assert hist.get("bot_id") == bot_id
        assert "snapshots" in hist
        assert isinstance(hist["snapshots"], list)

        # 4) positions（持仓）
        r = client.get(
            f"/api/tradingbots/{bot_id}/positions",
            headers=auth_headers,
        )
        assert r.status_code == 200
        pos = r.get_json()
        assert pos.get("success") is True
        assert pos.get("bot_id") == bot_id
        assert "positions" in pos
        assert isinstance(pos["positions"], list)

        # 5) pending-orders（App 若未接 client，后端仍应可用）
        r = client.get(
            f"/api/tradingbots/{bot_id}/pending-orders",
            headers=auth_headers,
        )
        assert r.status_code == 200
        ord_data = r.get_json()
        assert ord_data.get("success") is True
        assert "orders" in ord_data

        # 6) ticker（默认 symbol 来自 Account_List）
        r = client.get(
            f"/api/tradingbots/{bot_id}/ticker",
            headers=auth_headers,
        )
        assert r.status_code == 200
        tick = r.get_json()
        assert "inst_id" in tick
        assert "last" in tick

        # 7) seasons
        r = client.get(
            f"/api/tradingbots/{bot_id}/seasons?limit=10",
            headers=auth_headers,
        )
        assert r.status_code == 200
        sea = r.get_json()
        assert sea.get("success") is True
        assert "seasons" in sea

    def test_account_profit_accounts_align_with_tradingbots_ids(
        self, client, auth_headers
    ):
        """盈亏列表中的 bot_id 应能在 tradingbots 中找到（或来自同一后端数据源）。"""
        r1 = client.get("/api/account-profit", headers=auth_headers)
        r2 = client.get("/api/tradingbots", headers=auth_headers)
        assert r1.status_code == 200 and r2.status_code == 200
        accounts = r1.get_json().get("accounts") or []
        bots = (r2.get_json().get("bots") or r2.get_json().get("tradingbots")) or []
        bot_ids = {b.get("tradingbot_id") for b in bots if b.get("tradingbot_id")}
        for a in accounts:
            bid = a.get("bot_id") or a.get("account_id")
            if bid:
                assert bid in bot_ids, (
                    f"account-profit 中的 bot_id={bid} 应在 /api/tradingbots 列表中"
                )
