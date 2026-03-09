# -*- coding: utf-8 -*-
"""Web 管控两个 bot 进程：server/simpleserver-lhg.py、server/simpleserver-hztech.py。
通过 nohup 启动；停止时先 SIGTERM 再 kill -9。"""
from __future__ import annotations

import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

# bot_id -> 管控脚本相对路径（相对于部署根目录）
BOT_SCRIPTS = {
    "simpleserver-lhg": "server/simpleserver-lhg.py",
    "simpleserver-hztech": "server/simpleserver-hztech.py",
}
# 停止时先 SIGTERM 等待秒数，再对剩余进程 kill -9
STOP_GRACEFUL_WAIT_SEC = 3


def _project_root() -> Path:
    """部署根目录：优先环境变量 MOBILEAPP_ROOT，否则取 server 上一级。"""
    root = os.environ.get("MOBILEAPP_ROOT")
    if root:
        return Path(root)
    return Path(__file__).resolve().parent.parent


def _script_path(bot_id: str) -> Path | None:
    """返回 bot 对应脚本的绝对路径，未知 bot_id 返回 None。"""
    rel = BOT_SCRIPTS.get(bot_id)
    if not rel:
        return None
    return _project_root() / rel


def _log_name(bot_id: str) -> str:
    """日志文件名：simpleserver-lhgYYYYMMDD.log"""
    return f"{bot_id}{datetime.now().strftime('%Y%m%d')}.log"


def _find_pids(bot_id: str) -> list[int]:
    """查找正在运行的该 bot 脚本进程 PID。"""
    rel = BOT_SCRIPTS.get(bot_id)
    if not rel:
        return []
    pattern = rel
    try:
        out = subprocess.run(
            ["pgrep", "-f", pattern],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode != 0 or not out.stdout.strip():
            return []
        return [int(x) for x in out.stdout.strip().split() if x.isdigit()]
    except (FileNotFoundError, subprocess.TimeoutExpired, ValueError):
        return []


def start(bot_id: str) -> dict:
    """启动指定 bot 进程。"""
    if bot_id not in BOT_SCRIPTS:
        return {"ok": False, "error": f"未知 bot_id: {bot_id}"}
    root = _project_root()
    script = _script_path(bot_id)
    if not script or not script.exists():
        return {"ok": False, "error": f"脚本不存在: {script}"}
    pids = _find_pids(bot_id)
    if pids:
        return {"ok": False, "error": "进程已在运行", "pids": pids}
    try:
        rel_script = BOT_SCRIPTS[bot_id]
        log_path = root / _log_name(bot_id)
        cmd = f"nohup python3 {rel_script} > {log_path} 2>&1 &"
        subprocess.run(cmd, cwd=str(root), shell=True, timeout=5)
        time.sleep(0.5)
        pids = _find_pids(bot_id)
        return {
            "ok": True,
            "message": "策略已启动",
            "log_file": str(log_path),
            "pids": pids,
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}


def stop(bot_id: str) -> dict:
    """停止指定 bot 进程：先 SIGTERM 再 kill -9。"""
    if bot_id not in BOT_SCRIPTS:
        return {"ok": False, "error": f"未知 bot_id: {bot_id}"}
    pids = _find_pids(bot_id)
    if not pids:
        return {"ok": True, "message": "策略未在运行", "killed": []}
    for pid in pids:
        try:
            subprocess.run(["kill", "-15", str(pid)], check=False, timeout=2)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
    time.sleep(STOP_GRACEFUL_WAIT_SEC)
    remaining = _find_pids(bot_id)
    killed = []
    for pid in remaining:
        try:
            subprocess.run(["kill", "-9", str(pid)], check=True, timeout=3)
            killed.append(pid)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
            pass
    return {"ok": True, "message": "策略已停止", "killed": killed}


def restart(bot_id: str) -> dict:
    """重启指定 bot：先 stop 再 start。"""
    stop_result = stop(bot_id)
    if not stop_result.get("ok"):
        return stop_result
    time.sleep(0.5)
    return start(bot_id)


def status() -> dict:
    """查询各 bot 运行状态。返回 { "bots": { bot_id: { "running": bool, "pids": [...] } }, "ok": True }。"""
    bots_status = {}
    for bid in BOT_SCRIPTS:
        pids = _find_pids(bid)
        script = _script_path(bid)
        bots_status[bid] = {
            "running": len(pids) > 0,
            "pids": pids,
            "script_exists": script.exists() if script else False,
            "script_path": str(script) if script else "",
        }
    return {
        "ok": True,
        "bots": bots_status,
    }
