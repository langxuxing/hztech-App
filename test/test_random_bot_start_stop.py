# -*- coding: utf-8 -*-
"""随机选取可管控 bot，串联 stop→start→校验→stop→校验（与 App 启停一致）。

每次随机抽取至多 _MAX_PICK 个 bot（当前为 6）。
日志通过 capsys.disabled() 直接打到终端，无需 pytest -s。
"""
from __future__ import annotations

import json
import random
import sys
import time
from datetime import datetime, timezone

import pytest

_server_dir = __import__("os").path.join(
    __import__("os").path.dirname(__file__), "..", "server"
)
sys.path.insert(0, __import__("os").path.abspath(_server_dir))

# 每轮随机启停的 bot 数量上限
_MAX_PICK = 6


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _emit(msg: str, data: dict | None = None) -> None:
    line = f"[random-bot {_ts()}] {msg}"
    if data is not None:
        line += " " + json.dumps(data, ensure_ascii=False)
    print(line, flush=True)


def _controllable_bot_ids(client, headers: dict) -> list[str]:
    r = client.get("/api/tradingbots", headers=headers)
    assert r.status_code == 200
    data = r.get_json()
    bots = data.get("bots") or data.get("tradingbots") or []
    out: list[str] = []
    for b in bots:
        if not b.get("can_control"):
            continue
        tid = (b.get("tradingbot_id") or "").strip()
        if tid:
            out.append(tid)
    return out


def _bot_row(client, headers: dict, bot_id: str) -> dict | None:
    r = client.get("/api/tradingbots", headers=headers)
    assert r.status_code == 200
    for b in r.get_json().get("bots") or []:
        if (b.get("tradingbot_id") or "") == bot_id:
            return b
    return None


def _status_snapshot(row: dict | None) -> dict:
    if not row:
        return {"error": "not_found"}
    return {
        "tradingbot_id": row.get("tradingbot_id"),
        "name": row.get("tradingbot_name"),
        "status": row.get("status"),
        "is_running": row.get("is_running"),
        "can_control": row.get("can_control"),
    }


def _run_random_bot_cycle(client, headers: dict) -> None:
    ids = _controllable_bot_ids(client, headers)
    _emit(
        "可管控 bot 列表",
        {"count": len(ids), "bot_ids": ids},
    )
    if len(ids) < 1:
        pytest.skip(
            "无 can_control 的 bot（检查 Account_List script_file 与 botctrl）"
        )

    k = min(_MAX_PICK, len(ids))
    picked = random.sample(ids, k=k)
    _emit(
        f"随机抽取（最多 {_MAX_PICK} 个）",
        {"sample_size": k, "picked": picked},
    )

    for bot_id in picked:
        _emit(f"--- 本轮 bot_id={bot_id} ---")

        r0 = client.post(
            f"/api/tradingbots/{bot_id}/stop", headers=headers
        )
        j0 = r0.get_json() if r0.is_json else {}
        _emit(
            "POST .../stop (先停干净)",
            {
                "http_status": r0.status_code,
                "body": j0,
            },
        )
        assert r0.status_code == 200, r0.get_data(as_text=True)

        row_a = _bot_row(client, headers, bot_id)
        _emit("GET /api/tradingbots 快照(停后)", _status_snapshot(row_a))

        r1 = client.post(
            f"/api/tradingbots/{bot_id}/start", headers=headers
        )
        j1 = r1.get_json() if r1.is_json else {}
        _emit(
            "POST .../start",
            {
                "http_status": r1.status_code,
                "body": j1,
            },
        )
        assert r1.status_code == 200, r1.get_data(as_text=True)
        assert j1.get("success") is True, f"start failed: {j1}"

        time.sleep(0.6)
        row = _bot_row(client, headers, bot_id)
        _emit("GET /api/tradingbots 快照(启后)", _status_snapshot(row))
        assert row is not None
        running = row.get("is_running") is True
        running = running or row.get("status") == "running"
        assert running, row
        _emit("校验", {"expect_running": True, "ok": True})

        r2 = client.post(
            f"/api/tradingbots/{bot_id}/stop", headers=headers
        )
        j2 = r2.get_json() if r2.is_json else {}
        _emit(
            "POST .../stop",
            {
                "http_status": r2.status_code,
                "body": j2,
            },
        )
        assert r2.status_code == 200
        assert j2.get("success") is True, f"stop failed: {j2}"

        time.sleep(0.5)
        row2 = _bot_row(client, headers, bot_id)
        _emit("GET /api/tradingbots 快照(再停后)", _status_snapshot(row2))
        assert row2 is not None
        stopped = row2.get("is_running") is False
        stopped = stopped or row2.get("status") == "stopped"
        assert stopped, row2
        _emit("校验", {"expect_stopped": True, "ok": True})

    _emit("全部完成", {"picked": picked})


class TestRandomBotStartStop:
    def test_random_start_stop_cycle(self, client, auth_headers, capsys):
        # 关闭 pytest 对 stdout/stderr 的捕获，日志直接出现在终端
        with capsys.disabled():
            _run_random_bot_cycle(client, auth_headers)
