# -*- coding: utf-8 -*-
"""OKX /account/balance 解析：权益 eq、cashBal 资产余额、availEq 可用保证金、占用。"""
from __future__ import annotations

from exchange.okx import _okx_aggregate_balance_from_payload


def test_aggregate_usdt_row_uses_eq_cashbal_avail_and_used():
    """USDT 行：权益 ``eq``，资产 ``cashBal``，可用 ``availEq``，占用 frozen 或 eq−avail。"""
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
    eq, cash_bal, avail, used, upl = _okx_aggregate_balance_from_payload(payload)
    assert abs(eq - 85800.5) < 1e-6
    assert abs(cash_bal - 85100.0) < 1e-6
    assert abs(avail - 85000.25) < 1e-6
    assert abs(used - (85800.5 - 85000.25)) < 1e-3
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
                        "cashBal": "120",
                    }
                ],
            }
        ],
    }
    eq, cash_bal, avail, used, upl = _okx_aggregate_balance_from_payload(payload)
    assert abs(eq - 55837.43) < 1e-6
    assert abs(cash_bal - 120.0) < 1e-6
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
    eq, cash_bal, avail, used, upl = _okx_aggregate_balance_from_payload(payload)
    assert abs(eq - 1.25) < 1e-9
    assert abs(avail - 0.5) < 1e-9
    assert abs(cash_bal - 0.5) < 1e-9
    assert abs(used - 0.75) < 1e-9
    assert abs(upl) < 1e-9


def test_aggregate_empty_details_uses_top_level_total_eq_avail_eq():
    """无 details 时用账户层 totalEq / availEq；cash_bal 与 avail 同口径回退。"""
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
    eq, cash_bal, avail, used, upl = _okx_aggregate_balance_from_payload(payload)
    assert abs(eq - 55837.43) < 1e-6
    assert abs(avail - 55415.62) < 1e-6
    assert abs(cash_bal - 55415.62) < 1e-6
    assert abs(upl) < 1e-9


def test_aggregate_fallback_total_when_no_cash_breakdown():
    """仅有 totalEq、无 details 时现金与可用回退为 totalEq。"""
    payload = {
        "code": "0",
        "data": [{"totalEq": "100", "upl": "0"}],
    }
    eq, cash_bal, avail, used, upl = _okx_aggregate_balance_from_payload(payload)
    assert eq == 100.0
    assert avail == 100.0
    assert cash_bal == 100.0
    assert used == 0.0
