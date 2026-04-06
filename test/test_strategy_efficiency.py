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


def test_close_pnl_efficiency_ratio():
    assert se.close_pnl_efficiency_ratio(10.0, 0.2) is not None
    assert abs(se.close_pnl_efficiency_ratio(10.0, 0.2) - 5e-8) < 1e-15
    assert se.close_pnl_efficiency_ratio(10.0, 0.0) is None


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


def test_fill_cash_gaps_middle_days():
    """K 线连续多日，仅部分日有快照：缺日补 sod=eod=上一真实日 eod，增量 0。"""
    bars = [
        {"day": "2026-04-01"},
        {"day": "2026-04-02"},
        {"day": "2026-04-03"},
    ]
    cash = {
        "2026-04-01": {
            "sod_cash": 100.0,
            "eod_cash": 103.0,
            "cash_delta_usdt": 3.0,
        },
        "2026-04-03": {
            "sod_cash": 103.0,
            "eod_cash": 108.0,
            "cash_delta_usdt": 5.0,
        },
    }
    filled = se.fill_cash_by_day_for_market_bars(bars, cash)
    assert filled["2026-04-01"]["cash_delta_usdt"] == 3.0
    assert filled["2026-04-02"]["sod_cash"] == 103.0
    assert filled["2026-04-02"]["eod_cash"] == 103.0
    assert filled["2026-04-02"]["cash_delta_usdt"] == 0.0
    assert filled["2026-04-03"]["cash_delta_usdt"] == 5.0


def test_fill_cash_before_first_snapshot_uses_anchor_sod():
    bars = [{"day": "2026-04-01"}, {"day": "2026-04-02"}]
    cash = {
        "2026-04-02": {
            "sod_cash": 200.0,
            "eod_cash": 205.0,
            "cash_delta_usdt": 5.0,
        },
    }
    filled = se.fill_cash_by_day_for_market_bars(bars, cash)
    assert filled["2026-04-01"]["sod_cash"] == 200.0
    assert filled["2026-04-01"]["eod_cash"] == 200.0
    assert filled["2026-04-01"]["cash_delta_usdt"] == 0.0


def test_fill_cash_empty_snapshots_all_zero():
    bars = [{"day": "2026-04-02"}]
    filled = se.fill_cash_by_day_for_market_bars(bars, {})
    assert filled["2026-04-02"]["cash_delta_usdt"] == 0.0
    assert filled["2026-04-02"]["sod_cash"] == 0.0


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


def test_normalize_bot_profit_snapshots_for_efficiency():
    raw = [
        {
            "snapshot_at": "2026-04-01T10:00:00.000Z",
            "equity_usdt": 100.0,
            "current_balance": 99.0,
        },
        {"snapshot_at": "2026-04-01T20:00:00.000Z", "current_balance": 104.0},
    ]
    norm = se.normalize_bot_profit_snapshots_for_efficiency(raw)
    assert len(norm) == 2
    assert norm[0]["cash_balance"] == 100.0
    assert norm[0]["equity_usdt"] == 100.0
    assert norm[1]["cash_balance"] == 104.0
    assert norm[1]["equity_usdt"] == 104.0
    by = se.daily_cash_delta_by_utc_day(norm)
    assert by["2026-04-01"]["cash_delta_usdt"] == 4.0


def test_merge_includes_equity_and_atr_placeholder():
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
    equity = {
        "2026-04-02": {
            "sod_equity": 2000.0,
            "eod_equity": 2020.0,
            "equity_delta_usdt": 20.0,
        }
    }
    rows = se.merge_daily_efficiency_rows(
        bars,
        cash,
        {"2026-04": 1000.0},
        equity_by_day=equity,
        month_equity_base_by_month={"2026-04": 2000.0},
        atr14_by_day={"2026-04-02": 0.05},
    )
    r = rows[0]
    assert abs(r["equity_delta_pct"] - 1.0) < 1e-9
    assert r["month_start_equity"] == 2000.0
    assert r["atr14"] == 0.05
    assert abs(r["threshold_0_1_atr_price"] - 0.005) < 1e-12
