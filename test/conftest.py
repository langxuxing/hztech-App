# -*- coding: utf-8 -*-
"""pytest 配置：测试用 DB、Flask client、登录 token。"""
from __future__ import annotations

import hashlib
import os
import sys
import tempfile

import pytest

# 使用临时 DB，避免污染开发库
_server_dir = os.path.join(os.path.dirname(__file__), "..", "server")
sys.path.insert(0, os.path.abspath(_server_dir))

import db  # noqa: E402

_tmp = tempfile.mkdtemp(prefix="hztech_test_")
db.DB_PATH = os.path.join(_tmp, "test.db")
db.init_db()
db.user_create("admin", hashlib.sha256(b"123").hexdigest())

from main import app  # noqa: E402

app.config["TESTING"] = True


@pytest.fixture
def client():
    return app.test_client()


@pytest.fixture
def token(client):
    r = client.post(
        "/api/login",
        json={"username": "admin", "password": "123"},
        content_type="application/json",
    )
    assert r.status_code == 200, r.get_data(as_text=True)
    data = r.get_json()
    assert data.get("success") and data.get("token")
    return data["token"]


@pytest.fixture
def auth_headers(token):
    return {"Authorization": f"Bearer {token}"}
