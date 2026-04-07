# -*- coding: utf-8 -*-
"""OKX /account/balance 解析：与 QTrader-web account_tester / account_profit_collector 口径一致。"""
from __future__ import annotations

from exchange.okx import _okx_aggregate_balance_from_payload


def test_aggregate_usdt_row_uses_eq_and_avail_eq_like_qtrader():
    """USDT 行：权益用 ``eq``，可用用 ``availEq``（缺省 ``availBal``），与 QTrader account_profit_collector 一致。"""
    payload = {
        "code": "0",
        "data": [
            {
                "totalEq": "90000.0",
                "upl": "-10",
                "availEq": "",
                "details": [
                    {
                        "ccy": "USDT",
                        "eq": "85800.5",
                        "availBal": "85000.25",
                        "cashBal": "85100",
                        "availEq": "85000.25",
                    }
                ],
            }
        ],
    }
    total, avail, upl = _okx_aggregate_balance_from_payload(payload)
    assert abs(total - 85800.5) < 1e-6
    assert abs(avail - 85000.25) < 1e-6
    assert abs(upl - (-10.0)) < 1e-6


def test_aggregate_usdt_eq_zero_falls_back_equity_to_total_eq():
    """USDT 的 eq 为 0 但账户 totalEq 有时仍用 totalEq 作权益（兜底）。"""
    payload = {
        "code": "0",
        "data": [
            {
                "totalEq": "55837.43",
                "upl": "0",
                "details": [
                    {
                        "ccy": "USDT",
                        "eq": "0",
                        "availBal": "100",
                        "availEq": "100",
                    }
                ],
            }
        ],
    }
    total, avail, upl = _okx_aggregate_balance_from_payload(payload)
    assert abs(total - 55837.43) < 1e-6
    assert abs(avail - 100.0) < 1e-6
    assert abs(upl) < 1e-9


def test_aggregate_no_usdt_sums_details_like_qtrader_tester():
    """无 USDT 行时按各币种 eq / avail 累加（与 account_tester 循环一致）。"""
    payload = {
        "code": "0",
        "data": [
            {
                "totalEq": "99999",
                "upl": "0",
                "details": [
                    {
                        "ccy": "BTC",
                        "eq": "1.25",
                        "availBal": "0.5",
                        "availEq": "0.5",
                    },
                ],
            }
        ],
    }
    total, avail, upl = _okx_aggregate_balance_from_payload(payload)
    assert abs(total - 1.25) < 1e-9
    assert abs(avail - 0.5) < 1e-9
    assert abs(upl) < 1e-9


def test_aggregate_empty_details_uses_top_level_total_eq_avail_eq():
    """无 details 时用账户层 totalEq / availEq。"""
    payload = {
        "code": "0",
        "data": [
            {
                "totalEq": "55837.43",
                "availEq": "55415.62",
                "upl": "0",
                "details": [],
            }
        ],
    }
    total, avail, upl = _okx_aggregate_balance_from_payload(payload)
    assert abs(total - 55837.43) < 1e-6
    assert abs(avail - 55415.62) < 1e-6
    assert abs(upl) < 1e-9


def test_aggregate_fallback_total_when_no_cash_breakdown():
    """仅有 totalEq、无 details 时现金回退为 totalEq。"""
    payload = {
        "code": "0",
        "data": [{"totalEq": "100", "upl": "0"}],
    }
    total, avail, upl = _okx_aggregate_balance_from_payload(payload)
    assert total == 100.0
    assert avail == 100.0
