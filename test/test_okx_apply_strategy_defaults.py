# -*- coding: utf-8 -*-
"""okx_apply_strategy_trading_defaults：非 SWAP 校验与 OKX 调用序列（mock）。"""
from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT / "baasapi") not in sys.path:
    sys.path.insert(0, str(ROOT / "baasapi"))

from exchange.okx import okx_apply_strategy_trading_defaults  # noqa: E402


def test_apply_rejects_non_swap_symbol():
    # 非「币对」形式时 okx_normalize_swap_inst_id 不会补全 -SWAP
    r = okx_apply_strategy_trading_defaults(None, "NOT_A_PAIR")
    assert r["ok"] is False
    assert r["errors"]


@patch("exchange.okx.okx_request")
def test_apply_full_sequence_when_net_mode(mock_req):
    calls: list[tuple[str, str]] = []

    def fake(method: str, path: str, **kwargs):
        calls.append((method, path.split("?")[0]))
        if method == "GET" and "/api/v5/account/config" in path:
            return ({"code": "0", "data": [{"posMode": "net_mode"}]}, None)
        if method == "POST" and "/api/v5/account/set-position-mode" in path:
            return ({"code": "0", "data": [{}]}, None)
        if method == "POST" and "/api/v5/account/set-leverage" in path:
            return ({"code": "0", "data": [{}]}, None)
        return (None, f"unexpected {method} {path}")

    mock_req.side_effect = fake
    r = okx_apply_strategy_trading_defaults(
        None, "PEPE-USDT-SWAP", target_leverage=50
    )
    assert r["ok"] is True
    paths = [c[1] for c in calls]
    assert "/api/v5/account/config" in paths
    assert "/api/v5/account/set-position-mode" in paths
    assert paths.count("/api/v5/account/set-leverage") == 2


@patch("exchange.okx.okx_request")
def test_apply_skips_position_mode_when_already_hedge(mock_req):
    def fake(method: str, path: str, **kwargs):
        if method == "GET" and "/api/v5/account/config" in path:
            return ({"code": "0", "data": [{"posMode": "long_short_mode"}]}, None)
        if method == "POST" and "/api/v5/account/set-leverage" in path:
            return ({"code": "0", "data": [{}]}, None)
        return (None, "unexpected")

    mock_req.side_effect = fake
    r = okx_apply_strategy_trading_defaults(None, "PEPE-USDT-SWAP")
    assert r["ok"] is True
    post_paths = [
        p for m, p in mock_req.call_args_list if m[0] == "POST"
    ]
    assert not any("set-position-mode" in str(a) for a in post_paths)
