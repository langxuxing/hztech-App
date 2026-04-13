# -*- coding: utf-8 -*-
"""后台 API 测试：登录、鉴权、策略、OKX、日志。"""
from __future__ import annotations

import pytest


class TestLogin:
    """POST /api/login"""

    def test_login_success(self, client):
        r = client.post(
            "/api/login",
            json={"username": "admin", "password": "i23321"},
            content_type="application/json",
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data["success"] is True
        assert "token" in data and len(data["token"]) > 0
        assert data.get("role") == "admin"
        assert isinstance(data.get("linked_account_ids"), list)

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
            ("GET", "/api/accounts"),
            ("GET", "/api/logs"),
            ("GET", "/api/users"),
            ("GET", "/api/okx/positions"),
            ("GET", "/api/accounts/simpleserver-lhg/positions"),
            ("GET", "/api/accounts/simpleserver-lhg/profit-history"),
            ("GET", "/api/accounts/simpleserver-lhg/seasons"),
            ("GET", "/api/accounts/simpleserver-lhg/tradingbot-events"),
            ("POST", "/api/tradingbots/simpleserver-lhg/start"),
            ("POST", "/api/tradingbots/simpleserver-lhg/stop"),
            ("POST", "/api/tradingbots/simpleserver-lhg/restart"),
            ("GET", "/api/me/customer-accounts"),
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
        r = client.get("/api/accounts", headers=auth_headers)
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
    """后台账户：仅以 Account_List.json 为准（不再使用 tradingbots.json）。"""

    LEGACY_MOCK_BOT_IDS = frozenset({"simpleserver-lhg", "simpleserver-hztech"})

    def test_tradingbots_excludes_default_simpleserver_when_no_tradingbots_json(
        self, client, auth_headers
    ):
        r = client.get("/api/accounts", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        bots = data.get("bots") or data.get("tradingbots") or []
        ids = {b.get("tradingbot_id") for b in bots if b.get("tradingbot_id")}
        assert self.LEGACY_MOCK_BOT_IDS.isdisjoint(ids), (
            f"/api/accounts 不应默认包含模拟 simpleserver bot，实际 ids={ids}"
        )

    def test_tradingbots_each_has_required_fields(self, client, auth_headers):
        r = client.get("/api/accounts", headers=auth_headers)
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
        r = client.get("/api/accounts", headers=auth_headers)
        assert r.status_code == 200
        data = r.get_json()
        bots = data.get("bots") or data.get("tradingbots") or []
        assert data.get("total") == len(bots), "total 应与 bots 长度一致"


class TestBotApi:
    """POST /api/tradingbots/<id>/start|stop|restart 需交易员或管理员 token"""

    def test_bot_start_with_token(self, client, trader_headers):
        r = client.post(
            "/api/tradingbots/simpleserver-lhg/start",
            headers=trader_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert "success" in data

    def test_bot_stop_with_token(self, client, trader_headers):
        r = client.post(
            "/api/tradingbots/simpleserver-lhg/stop",
            headers=trader_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert "success" in data

    def test_bot_restart_with_token(self, client, trader_headers):
        r = client.post(
            "/api/tradingbots/simpleserver-lhg/restart",
            headers=trader_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert "success" in data

    def test_bot_unknown_id_404(self, client, trader_headers):
        r = client.post(
            "/api/tradingbots/unknown_bot/start",
            headers=trader_headers,
        )
        assert r.status_code == 404

    def test_bot_start_ok_for_admin(self, client, auth_headers):
        r = client.post(
            "/api/tradingbots/simpleserver-lhg/start",
            headers=auth_headers,
        )
        assert r.status_code == 200


class TestPositionsApi:
    """GET /api/accounts/<account_id>/positions 从后台读取当前持仓（需 token）"""

    def test_positions_require_auth(self, client):
        r = client.get("/api/accounts/simpleserver-lhg/positions")
        assert r.status_code == 401

    def test_positions_with_token_returns_structure(self, client, auth_headers):
        """带 token 调用返回 200，且包含 success、bot_id、positions 列表。"""
        r = client.get(
            "/api/accounts/simpleserver-lhg/positions",
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
            "/api/accounts/simpleserver-hztech/positions",
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

    def test_users_forbidden_for_trader(self, client, trader_headers):
        r = client.get("/api/users", headers=trader_headers)
        assert r.status_code == 403

    def test_users_post_and_delete(self, client, auth_headers):
        r = client.post(
            "/api/users",
            headers=auth_headers,
            json={
                "username": "tmp_user_z9",
                "password": "pw",
                "role": "trader",
            },
            content_type="application/json",
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        uid = (data.get("user") or {}).get("id")
        assert uid
        r2 = client.delete(f"/api/users/{uid}", headers=auth_headers)
        assert r2.status_code == 200
        assert r2.get_json().get("success") is True

    def test_users_post_full_name_phone(self, client, auth_headers):
        r = client.post(
            "/api/users",
            headers=auth_headers,
            json={
                "username": "tmp_user_profile_1",
                "password": "secret12",
                "role": "trader",
                "full_name": "测试全名",
                "phone": "13800138000",
            },
            content_type="application/json",
        )
        assert r.status_code == 200
        u = (r.get_json() or {}).get("user") or {}
        assert u.get("full_name") == "测试全名"
        assert u.get("phone") == "13800138000"
        uid = u.get("id")
        assert uid
        r2 = client.patch(
            f"/api/users/{uid}",
            headers=auth_headers,
            json={"full_name": "新名字", "phone": ""},
            content_type="application/json",
        )
        assert r2.status_code == 200
        u2 = (r2.get_json() or {}).get("user") or {}
        assert u2.get("full_name") == "新名字"
        assert u2.get("phone") == ""
        client.delete(f"/api/users/{uid}", headers=auth_headers)

    def test_users_cannot_demote_last_admin(self, client, auth_headers):
        r = client.get("/api/users", headers=auth_headers)
        aid = next(
            u["id"]
            for u in r.get_json()["users"]
            if u.get("role") == "admin" and u.get("username") == "admin"
        )
        r2 = client.patch(
            f"/api/users/{aid}",
            headers=auth_headers,
            json={"role": "trader"},
            content_type="application/json",
        )
        assert r2.status_code == 400
        assert "管理员" in (r2.get_json() or {}).get("message", "")


class TestStrategyAnalystAutoNet:
    """POST /api/strategy-analyst/auto-net-test（管理员与策略分析师）"""

    def test_auto_net_ok_for_analyst(self, client, analyst_headers):
        r = client.post(
            "/api/strategy-analyst/auto-net-test",
            headers=analyst_headers,
            json={"bot_id": "simpleserver-lhg"},
            content_type="application/json",
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True

    def test_auto_net_ok_for_admin(self, client, auth_headers):
        r = client.post(
            "/api/strategy-analyst/auto-net-test",
            headers=auth_headers,
            json={},
            content_type="application/json",
        )
        assert r.status_code == 200
        assert r.get_json().get("success") is True

    def test_auto_net_forbidden_for_trader(self, client, trader_headers):
        r = client.post(
            "/api/strategy-analyst/auto-net-test",
            headers=trader_headers,
            json={},
            content_type="application/json",
        )
        assert r.status_code == 403

    def test_auto_net_forbidden_for_customer(self, client):
        import hashlib

        import db as tdb

        tdb.user_create("cust_autonet", hashlib.sha256(b"x").hexdigest())
        conn = tdb.get_conn()
        conn.execute(
            "UPDATE users SET role = ?, linked_account_ids = ? WHERE LOWER(username) = LOWER(?)",
            ("customer", '["simpleserver-lhg"]', "cust_autonet"),
        )
        conn.commit()
        conn.close()
        lr = client.post(
            "/api/login",
            json={"username": "cust_autonet", "password": "x"},
            content_type="application/json",
        )
        assert lr.status_code == 200
        tok = lr.get_json()["token"]
        h = {"Authorization": f"Bearer {tok}"}
        r = client.post(
            "/api/strategy-analyst/auto-net-test",
            headers=h,
            json={},
            content_type="application/json",
        )
        assert r.status_code == 403


class TestCustomerScope:
    """客户仅能看到绑定账户（linked_account_ids）。"""

    def test_customer_tradingbots_filtered(self, client):
        import hashlib

        import db as tdb

        tdb.user_create("cust_rb", hashlib.sha256(b"x").hexdigest())
        conn = tdb.get_conn()
        conn.execute(
            "UPDATE users SET role = ?, linked_account_ids = ? WHERE LOWER(username) = LOWER(?)",
            ("customer", '["Hztech_Devops"]', "cust_rb"),
        )
        conn.commit()
        conn.close()
        lr = client.post(
            "/api/login",
            json={"username": "cust_rb", "password": "x"},
            content_type="application/json",
        )
        assert lr.status_code == 200
        tok = lr.get_json()["token"]
        assert lr.get_json().get("role") == "customer"
        h = {"Authorization": f"Bearer {tok}"}
        r = client.get("/api/accounts", headers=h)
        assert r.status_code == 200
        bots = r.get_json().get("bots") or []
        ids = {b.get("tradingbot_id") for b in bots}
        assert ids == {"Hztech_Devops"}

    def test_customer_account_profit_filtered(self, client):
        import hashlib

        import db as tdb

        tdb.user_create("cust_profit", hashlib.sha256(b"x").hexdigest())
        conn = tdb.get_conn()
        conn.execute(
            "UPDATE users SET role = ?, linked_account_ids = ? WHERE LOWER(username) = LOWER(?)",
            ("customer", '["Hztech_Devops"]', "cust_profit"),
        )
        conn.commit()
        conn.close()
        lr = client.post(
            "/api/login",
            json={"username": "cust_profit", "password": "x"},
            content_type="application/json",
        )
        assert lr.status_code == 200
        tok = lr.get_json()["token"]
        h = {"Authorization": f"Bearer {tok}"}
        r = client.get("/api/account-profit", headers=h)
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        accounts = data.get("accounts") or []
        ids = {
            (a.get("bot_id") or a.get("account_id") or "").strip() for a in accounts
        }
        ids.discard("")
        assert ids <= {"Hztech_Devops"}

    def test_customer_accounts_filtered_when_authenticated(
        self, client, auth_headers
    ):
        import hashlib

        import db as tdb

        tdb.user_create("cust_st", hashlib.sha256(b"x").hexdigest())
        conn = tdb.get_conn()
        conn.execute(
            "UPDATE users SET role = ?, linked_account_ids = ? WHERE LOWER(username) = LOWER(?)",
            ("customer", '["simpleserver-lhg"]', "cust_st"),
        )
        conn.commit()
        conn.close()
        lr = client.post(
            "/api/login",
            json={"username": "cust_st", "password": "x"},
            content_type="application/json",
        )
        assert lr.status_code == 200
        tok = lr.get_json()["token"]
        h = {"Authorization": f"Bearer {tok}"}
        r_admin = client.get("/api/accounts", headers=auth_headers)
        assert r_admin.status_code == 200
        admin_list = r_admin.get_json() or {}
        admin_bots = admin_list.get("bots") or []
        full_ids = {
            (b.get("tradingbot_id") or b.get("bot_id") or "").strip()
            for b in admin_bots
        }
        full_ids.discard("")
        r = client.get("/api/accounts", headers=h)
        assert r.status_code == 200
        data = r.get_json()
        cust_bots = data.get("bots") or []
        cust_ids = {
            (b.get("tradingbot_id") or b.get("bot_id") or "").strip()
            for b in cust_bots
        }
        cust_ids.discard("")
        assert cust_ids <= full_ids
        assert cust_ids <= {"simpleserver-lhg"}
        if "simpleserver-hztech" in full_ids:
            assert "simpleserver-hztech" not in cust_ids


class TestCustomerAccountSetupApi:
    """客户账户配置：GET /api/me/customer-accounts、PUT okx-json。"""

    def test_customer_accounts_forbidden_for_admin(self, client, auth_headers):
        r = client.get("/api/me/customer-accounts", headers=auth_headers)
        assert r.status_code == 403

    def test_customer_accounts_lists_bindings(self, client):
        import hashlib

        import db as tdb

        tdb.user_create("cust_bind", hashlib.sha256(b"x").hexdigest())
        conn = tdb.get_conn()
        conn.execute(
            "UPDATE users SET role = ?, linked_account_ids = ? WHERE LOWER(username) = LOWER(?)",
            ("customer", '["OKX_Hztech_Devops"]', "cust_bind"),
        )
        conn.commit()
        conn.close()
        lr = client.post(
            "/api/login",
            json={"username": "cust_bind", "password": "x"},
            content_type="application/json",
        )
        assert lr.status_code == 200
        tok = lr.get_json()["token"]
        h = {"Authorization": f"Bearer {tok}"}
        r = client.get("/api/me/customer-accounts", headers=h)
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        accounts = data.get("accounts") or []
        assert len(accounts) == 1
        row = accounts[0]
        assert row.get("account_id") == "OKX_Hztech_Devops"
        assert "key_file_exists" in row
        assert "missing_in_account_list" in row

    def test_put_okx_json_forbidden_wrong_account(self, client):
        import hashlib

        import db as tdb

        tdb.user_create("cust_put", hashlib.sha256(b"x").hexdigest())
        conn = tdb.get_conn()
        conn.execute(
            "UPDATE users SET role = ?, linked_account_ids = ? WHERE LOWER(username) = LOWER(?)",
            ("customer", '["OKX_Hztech_Devops"]', "cust_put"),
        )
        conn.commit()
        conn.close()
        lr = client.post(
            "/api/login",
            json={"username": "cust_put", "password": "x"},
            content_type="application/json",
        )
        tok = lr.get_json()["token"]
        h = {"Authorization": f"Bearer {tok}"}
        r = client.put(
            "/api/me/customer-accounts/other-bot/okx-json",
            headers=h,
            json={"api": {"key": "a", "secret": "b", "passphrase": "c"}},
            content_type="application/json",
        )
        assert r.status_code == 403

    def test_put_okx_json_validation_error(self, client):
        import hashlib

        import db as tdb

        tdb.user_create("cust_bad", hashlib.sha256(b"x").hexdigest())
        conn = tdb.get_conn()
        conn.execute(
            "UPDATE users SET role = ?, linked_account_ids = ? WHERE LOWER(username) = LOWER(?)",
            ("customer", '["OKX_Hztech_Devops"]', "cust_bad"),
        )
        conn.commit()
        conn.close()
        lr = client.post(
            "/api/login",
            json={"username": "cust_bad", "password": "x"},
            content_type="application/json",
        )
        tok = lr.get_json()["token"]
        h = {"Authorization": f"Bearer {tok}"}
        r = client.put(
            "/api/me/customer-accounts/OKX_Hztech_Devops/okx-json",
            headers=h,
            json={"no_api": True},
            content_type="application/json",
        )
        assert r.status_code == 400


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
            assert "equity_profit_amount" in acc
            assert "equity_profit_percent" in acc


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
    """GET /api/accounts/<account_id>/profit-history 盈利历史（需 token）"""

    def test_profit_history_with_token(self, client, auth_headers):
        r = client.get(
            "/api/accounts/simpleserver-lhg/profit-history",
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
            "/api/accounts/simpleserver-lhg/profit-history?limit=10",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert len(data["snapshots"]) <= 10


class TestBotSeasonsApi:
    """GET /api/accounts/<account_id>/seasons 赛季列表（需 token）"""

    def test_seasons_with_token(self, client, auth_headers):
        r = client.get(
            "/api/accounts/simpleserver-lhg/seasons",
            headers=auth_headers,
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data.get("success") is True
        assert data.get("bot_id") == "simpleserver-lhg"
        assert "seasons" in data
        assert isinstance(data["seasons"], list)


class TestBotTradingbotEventsApi:
    """GET /api/accounts/<account_id>/tradingbot-events 启停事件（需 token）"""

    def test_events_with_token(self, client, auth_headers):
        r = client.get(
            "/api/accounts/simpleserver-lhg/tradingbot-events",
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
