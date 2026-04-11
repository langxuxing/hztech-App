# -*- coding: utf-8 -*-
"""tradingbot_ctrl：可配置脚本目录、mock 脚本的启停与赛季子命令测试。"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

_server_dir = os.path.join(os.path.dirname(__file__), "..", "baasapi")
sys.path.insert(0, os.path.abspath(_server_dir))


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def _mobileapp_root():
    os.environ.setdefault("MOBILEAPP_ROOT", str(_repo_root()))
    yield


def test_resolve_moneyflow_001_basename():
    from accounts import AccountMgr as am

    import tradingbot_ctrl as tc

    os.environ.pop("HZTECH_TRADINGBOT_CTRL_DIR", None)
    p = tc.resolve_account_script_file("moneyflow_001.sh")
    assert p is not None
    assert p.name == "moneyflow_001.sh"
    expect = (am.ACCOUNTS_DIR / "tradingbot_ctrl").resolve()
    assert p.parent.resolve() == expect


def test_tradingbot_ctrl_dir_default_and_env(monkeypatch):
    from accounts import AccountMgr as am

    import tradingbot_ctrl as tc

    monkeypatch.delenv("HZTECH_TRADINGBOT_CTRL_DIR", raising=False)
    default_ctrl = (am.ACCOUNTS_DIR / "tradingbot_ctrl").resolve()
    assert tc.tradingbot_ctrl_dir() == default_ctrl

    monkeypatch.setenv("HZTECH_TRADINGBOT_CTRL_DIR", "tradingbot_ctrl")
    assert tc.tradingbot_ctrl_dir() == default_ctrl


def test_start_stop_restart_mock_script():
    from accounts import AccountMgr as am

    import tradingbot_ctrl as tc

    aid = "pytest_tradingbot_shell_dev"
    script = am.ACCOUNTS_DIR / "tradingbot_ctrl" / "moneyflow_test_001.sh"
    assert script.is_file()

    tc.stop_shell_bot(aid, script)
    st = tc.start_shell_bot(aid, script)
    assert st.get("ok"), st
    assert st.get("pids")

    assert tc.stop_shell_bot(aid, script).get("ok")

    st3 = tc.start_shell_bot(aid, script)
    assert st3.get("ok"), st3
    assert tc.stop_shell_bot(aid, script).get("ok")


def test_season_start_stop_mock_script():
    from accounts import AccountMgr as am

    import tradingbot_ctrl as tc

    aid = "pytest_tradingbot_season_dev"
    script = am.ACCOUNTS_DIR / "tradingbot_ctrl" / "moneyflow_test_001.sh"
    assert tc.run_shell_season_action(aid, script, "start").get("ok")
    assert tc.run_shell_season_action(aid, script, "stop").get("ok")


def test_all_dev_mock_scripts_usage():
    from accounts import AccountMgr as am

    ctrl = am.ACCOUNTS_DIR / "tradingbot_ctrl"
    names = [
        "moneyflow_test_001.sh",
        "moneyflow_test_002.sh",
        "moneyflow_test_003.sh",
        "moneyflow_test_004.sh",
        "moneyflow_test_005.sh",
        "moneyflow_test_mainrepo.sh",
    ]
    for n in names:
        r = subprocess.run(
            ["bash", str(ctrl / n)],
            cwd=str(_repo_root()),
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert r.returncode == 1
        combined = f"{r.stderr or ''}\n{r.stdout or ''}".lower()
        assert "usage" in combined
