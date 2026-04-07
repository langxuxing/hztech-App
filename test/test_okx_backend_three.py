# -*- coding: utf-8 -*-
"""后台与 OKX 相关的三条 HTTP 路径联调（需网络，可能因 1010/密钥失败但接口结构应正确）。"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

_ACCOUNTS = Path(__file__).resolve().parent.parent / "server" / "accounts"
_BOTCONFIG = _ACCOUNTS / "tradingbots.json"
_ACCOUNT_LIST = _ACCOUNTS / "Account_List.json"


def _bot_ids_from_tradingbots_json() -> list[str]:
    if not _BOTCONFIG.is_file():
        return []
    try:
        raw = json.loads(_BOTCONFIG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if isinstance(raw, list):
        rows = raw
    elif isinstance(raw, dict):
        rows = raw.get("bots") or raw.get("tradingbots") or []
    else:
        rows = []
    ids: list[str] = []
    for b in rows:
        if not isinstance(b, dict):
            continue
        bid = (b.get("tradingbot_id") or "").strip()
        if bid:
            ids.append(bid)
        if len(ids) >= 3:
            break
    return ids


def _bot_ids_from_account_list() -> list[str]:
    """tradingbots.json 不存在时，用 Account_List 中启用账户的 account_id（至多 3 个）。"""
    if not _ACCOUNT_LIST.is_file():
        return []
    try:
        rows = json.loads(_ACCOUNT_LIST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(rows, list):
        return []
    ids: list[str] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        if row.get("enbaled") is False:
            continue
        aid = (row.get("account_id") or "").strip()
        if aid:
            ids.append(aid)
        if len(ids) >= 3:
            break
    return ids


def _first_three_bot_ids() -> list[str]:
    ids = _bot_ids_from_tradingbots_json()
    if ids:
        return ids
    ids = _bot_ids_from_account_list()
    if ids:
        return ids
    return []


# 无 tradingbots.json 时依赖 Account_List；二者皆空时用仓库内常见启用账户占位
_BOT_IDS_PARAM = _first_three_bot_ids() or ["Alang_Sandbox"]


class TestOkxBackendThreeRoutes:
    """三类会访问 OKX 的后台 API（余额类、全局持仓、按 bot 持仓）。"""

    def test_account_profit_calls_okx_balance_path(self, client, auth_headers):
        """GET /api/account-profit：对每个 bot 使用 account_api_file 拉余额/权益。"""
        r = client.get("/api/account-profit", headers=auth_headers)
        assert r.status_code == 200, r.get_data(as_text=True)
        data = r.get_json()
        assert data.get("success") is True
        assert "accounts" in data
        assert isinstance(data["accounts"], list)

    def test_okx_positions_global(self, client, auth_headers):
        """GET /api/okx/positions：使用默认 OKX 配置拉持仓。"""
        r = client.get("/api/okx/positions", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert "positions" in data
        assert "positions_error" in data

    @pytest.mark.parametrize("bot_id", _BOT_IDS_PARAM)
    def test_tradingbot_positions_per_bot_config(
        self, client, auth_headers, bot_id
    ):
        """GET /api/tradingbots/<bot_id>/positions：按 bot 解析 OKX 配置拉持仓。"""
        r = client.get(
            f"/api/tradingbots/{bot_id}/positions",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert data.get("bot_id") == bot_id
        assert isinstance(data.get("positions"), list)
        err = data.get("positions_error")
        assert err is None or isinstance(err, str)
        if err and "1010" in err:
            assert "okx_debug" in data
            od = data["okx_debug"]
            assert isinstance(od, dict)
            assert "server_egress_ip" in od or "note" in od
