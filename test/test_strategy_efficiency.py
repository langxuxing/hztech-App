# -*- coding: utf-8 -*-
from __future__ import annotations

import sys
import os

_server = os.path.join(os.path.dirname(__file__), "..", "server")
sys.path.insert(0, os.path.abspath(_server))

import strategy_efficiency as se  # noqa: E402


def test_daily_cash_delta_two_days():
    snaps = [
        {"snapshot_at": "2026-04-01T10:00:00.000Z", "cash_balance": 100.0},
        {"snapshot_at": "2026-04-01T18:00:00.000Z", "cash_balance": 103.0},
        {"snapshot_at": "2026-04-02T12:00:00.000Z", "cash_balance": 105.0},
    ]
    by = se.daily_cash_delta_by_utc_day(snaps)
    assert "2026-04-01" in by
    assert by["2026-04-01"]["cash_delta_usdt"] == 3.0
    assert "2026-04-02" in by
    assert by["2026-04-02"]["cash_delta_usdt"] == 2.0


def test_daily_cash_delta_negative_clamped_to_zero():
    """余额下降日：日变动按 0 计（现金余额口径仅体现非负增量）。"""
    snaps = [
        {"snapshot_at": "2026-04-01T10:00:00.000Z", "cash_balance": 100.0},
        {"snapshot_at": "2026-04-01T18:00:00.000Z", "cash_balance": 97.0},
    ]
    by = se.daily_cash_delta_by_utc_day(snaps)
    assert by["2026-04-01"]["sod_cash"] == 100.0
    assert by["2026-04-01"]["eod_cash"] == 97.0
    assert by["2026-04-01"]["cash_delta_usdt"] == 0.0


def test_merge_efficiency_ratio():
    bars = [
        {
            "day": "2026-04-02",
            "open": 1.0,
            "high": 1.1,
            "low": 0.9,
            "close": 1.0,
            "tr": 0.2,
        }
    ]
    cash = {
        "2026-04-02": {
            "sod_cash": 1000.0,
            "eod_cash": 1010.0,
            "cash_delta_usdt": 10.0,
        }
    }
    rows = se.merge_daily_efficiency_rows(bars, cash, None)
    assert len(rows) == 1
    r = rows[0]
    assert r["tr_pct"] == 20.0
    # 无月初表时用当日 sod 作分母：10/1000*100
    assert r["cash_delta_pct"] == 1.0
    assert r["month_start_cash"] is None
    # 10 / (0.2 * 1e9) = 5e-8
    assert abs(r["efficiency_ratio"] - 5e-8) < 1e-15


def test_month_start_cash_by_month_from_snapshots():
    snaps = [
        {"snapshot_at": "2026-03-28T12:00:00.000Z", "cash_balance": 5000.0},
        {"snapshot_at": "2026-04-02T10:00:00.000Z", "cash_balance": 1000.0},
    ]
    m = se.month_start_cash_by_month_from_snapshots(snaps)
    assert m.get("2026-04") == 5000.0


def test_merge_cash_yield_uses_month_base():
    bars = [
        {
            "day": "2026-04-02",
            "open": 1.0,
            "high": 1.1,
            "low": 0.9,
            "close": 1.0,
            "tr": 0.2,
        }
    ]
    cash = {
        "2026-04-02": {
            "sod_cash": 1000.0,
            "eod_cash": 1010.0,
            "cash_delta_usdt": 10.0,
        }
    }
    rows = se.merge_daily_efficiency_rows(bars, cash, {"2026-04": 2000.0})
    r = rows[0]
    assert abs(r["cash_delta_pct"] - 0.5) < 1e-9
    assert r["month_start_cash"] == 2000.0
