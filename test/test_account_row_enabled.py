# -*- coding: utf-8 -*-
"""account_row_is_enabled：enbaled / enabled 字段兼容。"""
from __future__ import annotations

import sys
from pathlib import Path

_server = Path(__file__).resolve().parent.parent / "server"
sys.path.insert(0, str(_server))


def test_account_row_is_enabled_prefers_enbaled_then_enabled():
    from accounts.test_account_key import account_row_is_enabled

    base = {"account_id": "x", "exchange_account": "OKX"}
    row_both = {**base, "enbaled": False, "enabled": True}
    assert account_row_is_enabled(row_both) is False
    assert account_row_is_enabled({**base, "enabled": False}) is False
    assert account_row_is_enabled({**base, "enbaled": True}) is True
    assert account_row_is_enabled({**base}) is True
    assert account_row_is_enabled({**base, "enable": False}) is False
    assert account_row_is_enabled({**base, "enable": True}) is True
    row_enable_enbaled = {**base, "enbaled": False, "enable": True}
    assert account_row_is_enabled(row_enable_enbaled) is False
