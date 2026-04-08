# -*- coding: utf-8 -*-
"""pytest 配置：测试用 DB、Flask client、登录 token。"""
from __future__ import annotations

import hashlib
import os
import sys
import tempfile
from pathlib import Path

import pytest

# 默认与运行时使用 database_config.json 的 profiles.test（PostgreSQL hztech 等）；
# 切换 SQLite：在配置中设 "profiles": { "test": { "backend": "sqlite" } } 或 export HZTECH_DB_BACKEND=sqlite
os.environ.setdefault("HZTECH_DB_PROFILE", "test")

_server_dir = os.path.join(os.path.dirname(__file__), "..", "baasapi")
sys.path.insert(0, os.path.abspath(_server_dir))

import db_backend  # noqa: E402

import db  # noqa: E402

if not db_backend.IS_POSTGRES:
    _tmp = tempfile.mkdtemp(prefix="hztech_")
    _test_db = Path(_tmp) / "test.db"
    db_backend.DB_PATH = _test_db
    db_backend.DB_DIR = _test_db.parent
    db.DB_PATH = _test_db

db.init_db()
_pwd = hashlib.sha256(b"i23321").hexdigest()
# init_db 可能已从 users.json 导入用户，其 password_hash 与测试口令不一致；统一清空后创建测试账号
_conn = db.get_conn()
_conn.execute("DELETE FROM users")
_conn.commit()
_conn.close()
assert db.user_create("admin", _pwd, role="admin")
assert db.user_create("trader", _pwd, role="trader")
assert db.user_create("analyst", _pwd, role="strategy_analyst")

from main import app  # noqa: E402

app.config["TESTING"] = True


@pytest.fixture
def client():
    return app.test_client()


@pytest.fixture
def token(client):
    r = client.post(
        "/api/login",
        json={"username": "admin", "password": "i23321"},
        content_type="application/json",
    )
    assert r.status_code == 200, r.get_data(as_text=True)
    data = r.get_json()
    assert data.get("success") and data.get("token")
    return data["token"]


@pytest.fixture
def auth_headers(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def trader_token(client):
    r = client.post(
        "/api/login",
        json={"username": "trader", "password": "i23321"},
        content_type="application/json",
    )
    assert r.status_code == 200, r.get_data(as_text=True)
    data = r.get_json()
    assert data.get("success") and data.get("token")
    assert data.get("role") == "trader"
    return data["token"]


@pytest.fixture
def trader_headers(trader_token):
    return {"Authorization": f"Bearer {trader_token}"}


@pytest.fixture
def analyst_token(client):
    r = client.post(
        "/api/login",
        json={"username": "analyst", "password": "i23321"},
        content_type="application/json",
    )
    assert r.status_code == 200, r.get_data(as_text=True)
    data = r.get_json()
    assert data.get("success") and data.get("token")
    assert data.get("role") == "strategy_analyst"
    return data["token"]


@pytest.fixture
def analyst_headers(analyst_token):
    return {"Authorization": f"Bearer {analyst_token}"}
