# -*- coding: utf-8 -*-
from accounts.AccountMgr import cash_profit_vs_initial, profit_vs_initial


def test_profit_vs_initial_basic():
    pa, pp = profit_vs_initial(10000.0, 10500.0)
    assert abs(pa - 500.0) < 1e-9
    assert abs(pp - 5.0) < 1e-9


def test_profit_vs_initial_zero_initial_percent_zero():
    pa, pp = profit_vs_initial(0.0, 100.0)
    assert abs(pa - 100.0) < 1e-9
    assert pp == 0.0


def test_profit_vs_initial_tiny_initial_percent_zero():
    pa, pp = profit_vs_initial(1e-20, 100.0)
    assert pa > 99.0
    assert pp == 0.0


def test_cash_profit_vs_initial_basic():
    pa, pp = cash_profit_vs_initial(10000.0, 9800.0)
    assert abs(pa - (-200.0)) < 1e-9
    assert abs(pp - (-2.0)) < 1e-9


def test_cash_profit_vs_initial_zero_initial_percent_zero():
    pa, pp = cash_profit_vs_initial(0.0, 50.0)
    assert abs(pa - 50.0) < 1e-9
    assert pp == 0.0
