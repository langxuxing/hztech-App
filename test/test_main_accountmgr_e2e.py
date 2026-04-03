# -*- coding: utf-8 -*-
"""
端到端：AccountMgr（Account_List.json）与 main.py /api/* 一致，
并与 Flutter App / Flutter Web 使用的 ApiClient 路径对齐。

覆盖：
- GET /api/account-profit、/api/tradingbots
- 每个启用账户：profit-history、positions、seasons、tradingbot-events
- 可选：pending-orders、ticker（与 account_profit_screen / web 链路一致）

说明：测试使用 conftest 临时 DB，但 AccountMgr 仍读仓库内真实 Account_List.json；
OKX 实时调用可能失败，接口仍须返回约定 JSON 结构。
"""
from __future__ import annotations

import sys
from urllib.parse import quote

import pytest

_server_dir = __import__("os").path.join(
    __import__("os").path.dirname(__file__), "..", "server"
)
sys.path.insert(0, __import__("os").path.abspath(_server_dir))


def _enabled_account_ids_from_mgr() -> list[str]:
    from Accounts import AccountMgr as am

    return [
        str(x["account_id"]).strip()
        for x in am.list_account_basics(enabled_only=True)
        if (x.get("account_id") or "").strip()
    ]


def _tradingbots_index(client, headers: dict) -> dict[str, dict]:
    r = client.get("/api/tradingbots", headers=headers)
    assert r.status_code == 200
    bots = r.get_json().get("bots") or []
    return {b["tradingbot_id"]: b for b in bots if b.get("tradingbot_id")}


def _profit_account_ids(client, headers: dict) -> set[str]:
    r = client.get("/api/account-profit", headers=headers)
    assert r.status_code == 200
    data = r.get_json()
    assert data.get("success") is True
    out: set[str] = set()
    for a in data.get("accounts") or []:
        bid = a.get("bot_id") or a.get("account_id")
        if bid:
            out.add(str(bid))
    return out


class TestMainAccountMgrE2E:
    """AccountMgr 启用账户 ⊆ /api/tradingbots 且 ⊆ /api/account-profit。"""

    def test_enabled_accounts_in_both_apis(self, client, auth_headers):
        mgr_ids = set(_enabled_account_ids_from_mgr())
        if not mgr_ids:
            pytest.skip("Account_List 无启用 OKX 账户")

        tb_map = _tradingbots_index(client, auth_headers)
        profit_ids = _profit_account_ids(client, auth_headers)

        missing_tb = mgr_ids - set(tb_map.keys())
        assert not missing_tb, (
            "下列 account_id 在 AccountMgr(enabled) 中但不在 /api/tradingbots: "
            f"{missing_tb}"
        )
        missing_profit = mgr_ids - profit_ids
        assert not missing_profit, (
            "下列 account_id 在 AccountMgr(enabled) 但不在 /api/account-profit: "
            f"{missing_profit}"
        )

        for aid in mgr_ids:
            row = tb_map[aid]
            assert "status" in row and "is_running" in row
            assert "can_control" in row
            assert row.get("tradingbot_name") or row.get("tradingbot_id")

    def test_per_account_routes_like_flutter_app_and_web(
        self, client, auth_headers
    ):
        """
        与 ApiClient 一致：getBotProfitHistory、getTradingbotPositions、
        getTradingbotSeasons；另测 events（审计）。
        Web：web_strategy_performance_screen / web_dashboard_screen 同源接口。
        """
        mgr_ids = _enabled_account_ids_from_mgr()
        if not mgr_ids:
            pytest.skip("Account_List 无启用 OKX 账户")

        # 至少抽一个含 @ 的 id（URL 编码与 Flask 路由）
        pick = mgr_ids[0]
        for aid in mgr_ids:
            if "@" in aid:
                pick = aid
                break

        enc = quote(pick, safe="")
        base = f"/api/tradingbots/{enc}"

        for path, keys in (
            (f"{base}/profit-history?limit=20", ("success", "snapshots")),
            (f"{base}/positions", ("success", "positions")),
            (f"{base}/seasons?limit=10", ("success", "seasons")),
            (f"{base}/tradingbot-events?limit=10", ("success", "events")),
            (f"{base}/pending-orders", ("success", "orders")),
        ):
            r = client.get(path, headers=auth_headers)
            assert r.status_code == 200, f"{path} -> {r.status_code}"
            data = r.get_json()
            assert data.get("success") is True, path
            for k in keys:
                assert k in data, (path, data.keys())

        r_t = client.get(f"{base}/ticker", headers=auth_headers)
        assert r_t.status_code == 200
        tick = r_t.get_json()
        assert "inst_id" in tick and "last" in tick

    def test_account_mgr_resolve_okx_matches_positions_error_semantics(
        self, client, auth_headers
    ):
        """无密钥文件时 resolve_okx_config_path 为 None，与 positions 错误文案一致。"""
        from Accounts import AccountMgr as am

        mgr_ids = _enabled_account_ids_from_mgr()
        if not mgr_ids:
            pytest.skip("Account_List 无启用 OKX 账户")

        for aid in mgr_ids[:5]:
            path = am.resolve_okx_config_path(aid)
            r = client.get(
                f"/api/tradingbots/{quote(aid, safe='')}/positions",
                headers=auth_headers,
            )
            assert r.status_code == 200
            data = r.get_json()
            assert data.get("success") is True
            if path is None or not path.is_file():
                err = (data.get("positions_error") or "").lower()
                assert "未找到" in err or "配置" in err or "密钥" in err, (
                    f"aid={aid} expected config error hint, got {data!r}"
                )
