# -*- coding: utf-8 -*-
"""直接子进程测试 accounts/tradingbot_ctrl/mock_bot_ctl.py。

根目录 conftest 会 import main（Flask），若本机 click/flask 不兼容请使用：
  pytest test/test_mock_bot_ctl.py --noconftest -v
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
BAASAPI = REPO / "baasapi"
MOCK_PY = BAASAPI / "accounts" / "tradingbot_ctrl" / "mock_bot_ctl.py"


@pytest.fixture
def isolated_mock_bot_env(tmp_path) -> dict[str, str]:
    db = tmp_path / "mock_bot_ctl.sqlite"
    env = os.environ.copy()
    env["MOBILEAPP_ROOT"] = str(REPO)
    env["HZTECH_DB_BACKEND"] = "sqlite"
    env["HZTECH_SQLITE_DB_PATH"] = str(db.resolve())
    env.pop("DATABASE_URL", None)
    return env


def _run_mock(
    args: list[str],
    env: dict[str, str],
    *,
    timeout: float = 120,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(MOCK_PY)] + args,
        cwd=str(BAASAPI),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def test_mock_bot_ctl_script_exists():
    assert MOCK_PY.is_file(), MOCK_PY


def test_mock_bot_ctl_requires_account_id(isolated_mock_bot_env):
    env = {
        k: v
        for k, v in isolated_mock_bot_env.items()
        if k != "HZTECH_ACCOUNT_ID"
    }
    env.pop("HZTECH_ACCOUNT_ID", None)
    r = _run_mock(["checkhealth"], env, timeout=30)
    assert r.returncode == 1
    assert "HZTECH_ACCOUNT_ID" in (r.stderr or "")


def test_mock_bot_ctl_unknown_command(isolated_mock_bot_env):
    env = dict(isolated_mock_bot_env)
    env["HZTECH_ACCOUNT_ID"] = "mock_ctlpytest_1"
    r = _run_mock(["not-a-command"], env, timeout=30)
    assert r.returncode == 1


def test_mock_bot_ctl_season_start_stop_json(isolated_mock_bot_env):
    env = dict(isolated_mock_bot_env)
    aid = "mock_ctlpytest_season"
    env["HZTECH_ACCOUNT_ID"] = aid
    env["HZTECH_MOCK_SCRIPT"] = "test_mock_bot_ctl.py"
    r1 = _run_mock(["season-start"], env, timeout=60)
    assert r1.returncode == 0, r1.stderr
    out1 = r1.stdout or ""
    assert '"ok"' in out1 or "ok" in out1.lower()

    r2 = _run_mock(["season-stop"], env, timeout=60)
    assert r2.returncode == 0, r2.stderr
    out2 = r2.stdout or ""
    assert '"ok"' in out2 or "ok" in out2.lower()


def test_mock_bot_ctl_start_stop_subprocess(isolated_mock_bot_env):
    env = dict(isolated_mock_bot_env)
    aid = "mock_ctlpytest_worker"
    env["HZTECH_ACCOUNT_ID"] = aid
    env["HZTECH_MOCK_SCRIPT"] = "test_start_stop"

    proc = subprocess.Popen(
        [sys.executable, str(MOCK_PY), "start"],
        cwd=str(BAASAPI),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        time.sleep(1.0)
        assert proc.poll() is None, "start 应前台阻塞运行"

        r_h = _run_mock(["checkhealth"], env, timeout=30)
        assert r_h.returncode == 0, r_h.stderr
        data = (r_h.stdout or "").lower()
        assert '"running": true' in data

        r_stop = _run_mock(["stop"], env, timeout=60)
        assert r_stop.returncode == 0, r_stop.stderr
    finally:
        proc.wait(timeout=15)


def test_mock_bot_ctl_stop_idempotent(isolated_mock_bot_env):
    env = dict(isolated_mock_bot_env)
    env["HZTECH_ACCOUNT_ID"] = "mock_ctlpytest_no_pid"
    r = _run_mock(["stop"], env, timeout=60)
    assert r.returncode == 0
