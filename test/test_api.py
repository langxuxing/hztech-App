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
            ("POST", "/api/tradingbots/simpleserver/start"),
            ("POST", "/api/tradingbots/simpleserver/stop"),
            ("POST", "/api/tradingbots/simpleserver/restart"),
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


class TestStrategyApi:
    """策略相关 API（/api/strategy/* 无需 token）"""

    def test_strategy_status(self, client):
        r = client.get("/api/strategy/status")
        assert r.status_code == 200
        data = r.get_json()
        assert "running" in data
        assert "pids" in data

    def test_strategy_start_stop_restart_no_auth(self, client):
        for path in ["/api/strategy/start", "/api/strategy/stop", "/api/strategy/restart"]:
            r = client.post(path)
            assert r.status_code == 200


class TestBotApi:
    """POST /api/tradingbots/<id>/start|stop|restart 需 token"""

    def test_bot_start_with_token(self, client, auth_headers):
        r = client.post(
            "/api/tradingbots/simpleserver/start",
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
