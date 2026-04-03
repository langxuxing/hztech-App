# -*- coding: utf-8 -*-
"""后台 API 测试：登录、鉴权、策略、OKX、日志。"""
from __future__ import annotations

import pytest


class TestLogin:
    """POST /api/login"""

    def test_login_success(self, client):
        r = client.post(
            "/api/login",
            json={"username": "admin", "password": "123"},
            content_type="application/json",
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data["success"] is True
        assert "token" in data and len(data["token"]) > 0

    def test_login_wrong_password(self, client):
        r = client.post(
            "/api/login",
            json={"username": "admin", "password": "wrong"},
            content_type="application/json",
        )
        assert r.status_code == 401
        assert r.get_json().get("success") is False

    def test_login_empty_body(self, client):
        r = client.post(
            "/api/login",
            json={},
            content_type="application/json",
        )
        assert r.status_code == 400

    def test_login_missing_password(self, client):
        r = client.post(
            "/api/login",
            json={"username": "admin"},
            content_type="application/json",
        )
        assert r.status_code == 400


class TestAuthRequired:
    """需 Bearer token 的接口无 token 时返回 401"""

    @pytest.mark.parametrize(
        "method,path",
        [
            ("GET", "/api/account-profit"),
            ("GET", "/api/tradingbots"),
            ("GET", "/api/logs"),
            ("GET", "/api/users"),
            ("GET", "/api/okx/positions"),
            ("GET", "/api/tradingbots/simpleserver-lhg/positions"),
            ("GET", "/api/tradingbots/simpleserver-lhg/profit-history"),
            ("GET", "/api/tradingbots/simpleserver-lhg/seasons"),
            ("GET", "/api/tradingbots/simpleserver-lhg/tradingbot-events"),
            ("POST", "/api/tradingbots/simpleserver-lhg/start"),
            ("POST", "/api/tradingbots/simpleserver-lhg/stop"),
            ("POST", "/api/tradingbots/simpleserver-lhg/restart"),
        ],
    )
    def test_401_without_token(self, client, method, path):
        if method == "GET":
            r = client.get(path)
        else:
            r = client.post(path)
        assert r.status_code == 401
        text = r.get_data(as_text=True)
        assert "token" in text.lower() or "登录" in text

    def test_account_profit_with_token(self, client, auth_headers):
        r = client.get("/api/account-profit", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert "accounts" in data

    def test_tradingbots_with_token(self, client, auth_headers):
        r = client.get("/api/tradingbots", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        assert "bots" in data or "tradingbots" in data
        assert data.get("total", 0) >= 0

    def test_logs_with_token(self, client, auth_headers):
        r = client.get("/api/logs", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert "logs" in data


class TestTradingbotsConfigAndApi:
    """后台账户：含 Account_List 启用账户 + tradingbots.json 中额外 bot（如 simpleserver-*）。"""

    EXPECTED_BOT_IDS = {
        "simpleserver-lhg",
        "simpleserver-hztech",
    }

    def test_tradingbots_returns_all_configured_bots(self, client, auth_headers):
        r = client.get("/api/tradingbots", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        bots = data.get("bots") or data.get("tradingbots") or []
        ids = {b.get("tradingbot_id") for b in bots if b.get("tradingbot_id")}
        assert len(bots) >= len(self.EXPECTED_BOT_IDS), (
            f"至少应包含 tradingbots.json 中的 bot，实际 {len(bots)}: {bots}"
        )
        assert self.EXPECTED_BOT_IDS.issubset(ids), (
            f"应包含 id 集合 {self.EXPECTED_BOT_IDS}，实际 {ids}"
        )

    def test_tradingbots_each_has_required_fields(self, client, auth_headers):
        r = client.get("/api/tradingbots", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        bots = data.get("bots") or data.get("tradingbots") or []
        for b in bots:
            assert b.get("tradingbot_id"), f"缺少 tradingbot_id: {b}"
            assert "tradingbot_name" in b or b.get("tradingbot_id")
            assert b.get("status") in ("running", "stopped"), f"无效 status: {b.get('status')}"
            assert "is_running" in b
            assert "can_control" in b

    def test_tradingbots_response_total_matches_list(self, client, auth_headers):
        r = client.get("/api/tradingbots", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        bots = data.get("bots") or data.get("tradingbots") or []
        assert data.get("total") == len(bots), "total 应与 bots 长度一致"


class TestStrategyApi:
    """策略相关 API（/api/strategy/* 无需 token；start/stop/restart 需 query bot_id）"""

    def test_strategy_status(self, client):
        r = client.get("/api/strategy/status")
        assert r.status_code == 200
        data = r.get_json()
        assert "bots" in data
        assert "simpleserver-lhg" in data["bots"]
        assert "simpleserver-hztech" in data["bots"]

    def test_strategy_start_stop_restart_need_bot_id(self, client):
        for path in ["/api/strategy/start", "/api/strategy/stop", "/api/strategy/restart"]:
            r = client.post(path)
            assert r.status_code == 400
        r = client.get("/api/strategy/status")
        assert r.status_code == 200
        r = client.post("/api/strategy/start?bot_id=simpleserver-lhg")
        assert r.status_code == 200


class TestBotApi:
    """POST /api/tradingbots/<id>/start|stop|restart 需 token"""

    def test_bot_start_with_token(self, client, auth_headers):
        r = client.post(
            "/api/tradingbots/simpleserver-lhg/start",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert "success" in data

    def test_bot_stop_with_token(self, client, auth_headers):
        r = client.post(
            "/api/tradingbots/simpleserver-lhg/stop",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert "success" in data

    def test_bot_restart_with_token(self, client, auth_headers):
        r = client.post(
            "/api/tradingbots/simpleserver-lhg/restart",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert "success" in data

    def test_bot_unknown_id_404(self, client, auth_headers):
        r = client.post(
            "/api/tradingbots/unknown_bot/start",
            headers=auth_headers,
        )
        assert r.status_code == 404


class TestPositionsApi:
    """GET /api/tradingbots/<bot_id>/positions 从后台读取当前持仓（需 token）"""

    def test_positions_require_auth(self, client):
        r = client.get("/api/tradingbots/simpleserver-lhg/positions")
        assert r.status_code == 401

    def test_positions_with_token_returns_structure(self, client, auth_headers):
        """带 token 调用返回 200，且包含 success、bot_id、positions 列表。"""
        r = client.get(
            "/api/tradingbots/simpleserver-lhg/positions",
            headers=auth_headers,
        )
        assert r.status_code == 200, r.get_data(as_text=True)
        data = r.get_json()
        assert data.get("success") is True
        assert data.get("bot_id") == "simpleserver-lhg"
        assert "positions" in data
        assert isinstance(data["positions"], list)
        for p in data["positions"]:
            assert "inst_id" in p
            assert "pos" in p
            assert "pos_side" in p
            assert "avg_px" in p
            assert "upl" in p

    def test_positions_known_bot_id(self, client, auth_headers):
        """指定 simpleserver-hztech 同样返回合规结构。"""
        r = client.get(
            "/api/tradingbots/simpleserver-hztech/positions",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert data.get("bot_id") == "simpleserver-hztech"
        assert isinstance(data.get("positions"), list)


class TestUsersApi:
    """GET /api/users 用户列表（需 token）"""

    def test_users_with_token(self, client, auth_headers):
        r = client.get("/api/users", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert "users" in data
        assert isinstance(data["users"], list)


class TestAccountProfitApi:
    """GET /api/account-profit 账户盈亏（需 token）"""

    def test_account_profit_structure(self, client, auth_headers):
        r = client.get("/api/account-profit", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert "accounts" in data
        assert "total_count" in data
        assert data["total_count"] == len(data["accounts"])
        for acc in data["accounts"]:
            assert "bot_id" in acc
            assert "current_balance" in acc
            assert "profit_amount" in acc
            assert "profit_percent" in acc


class TestOkxPositionsGlobalApi:
    """GET /api/okx/positions 全局 OKX 持仓（需 token）"""

    def test_okx_positions_with_token(self, client, auth_headers):
        r = client.get("/api/okx/positions", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert "positions" in data
        assert isinstance(data["positions"], list)


class TestBotProfitHistoryApi:
    """GET /api/tradingbots/<bot_id>/profit-history 盈利历史（需 token）"""

    def test_profit_history_with_token(self, client, auth_headers):
        r = client.get(
            "/api/tradingbots/simpleserver-lhg/profit-history",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert data.get("bot_id") == "simpleserver-lhg"
        assert "snapshots" in data
        assert isinstance(data["snapshots"], list)

    def test_profit_history_limit_param(self, client, auth_headers):
        r = client.get(
            "/api/tradingbots/simpleserver-lhg/profit-history?limit=10",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert len(data["snapshots"]) <= 10


class TestBotSeasonsApi:
    """GET /api/tradingbots/<bot_id>/seasons 赛季列表（需 token）"""

    def test_seasons_with_token(self, client, auth_headers):
        r = client.get(
            "/api/tradingbots/simpleserver-lhg/seasons",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert data.get("bot_id") == "simpleserver-lhg"
        assert "seasons" in data
        assert isinstance(data["seasons"], list)


class TestBotTradingbotEventsApi:
    """GET /api/tradingbots/<bot_id>/tradingbot-events 启停事件（需 token）"""

    def test_events_with_token(self, client, auth_headers):
        r = client.get(
            "/api/tradingbots/simpleserver-lhg/tradingbot-events",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert data.get("bot_id") == "simpleserver-lhg"
        assert "events" in data
        assert isinstance(data["events"], list)


class TestOkxApi:
    """GET /api/okx/info 无需 token"""

    def test_okx_info(self, client):
        r = client.get("/api/okx/info")
        # 有配置文件 200，无则 404
        assert r.status_code in (200, 404)
        if r.status_code == 200:
            data = r.get_json()
            assert data.get("ok") is True
            assert "info" in data
