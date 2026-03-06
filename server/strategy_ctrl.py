# -*- coding: utf-8 -*-
"""Web 管控进程：启动、停止、重启 server/simpleserver.py。通过 nohup 启动，kill -9 停止。"""
from __future__ import annotations

import os
import subprocess
from datetime import datetime
from pathlib import Path

# 管控脚本相对路径（相对于部署根目录）
CONTROLLED_SCRIPT = "server/simpleserver.py"
# 进程匹配用：ps -ef | grep server/simpleserver.py 可与其他 python 区分
STRATEGY_PROCESS_PATTERN = "server/simpleserver.py"


def _project_root() -> Path:
    """部署根目录：优先环境变量 MOBILEAPP_ROOT，否则取 server 上一级。"""
    root = os.environ.get("MOBILEAPP_ROOT")
    if root:
        return Path(root)
    return Path(__file__).resolve().parent.parent


def _log_name() -> str:
    """日志文件名：simpleserverYYYYMMDD.log"""
    return f"simpleserver{datetime.now().strftime('%Y%m%d')}.log"


def _strategy_script_path() -> Path:
    return _project_root() / CONTROLLED_SCRIPT


def _find_pids() -> list[int]:
    """查找正在运行的 server/simpleserver.py 进程 PID（ps -ef | grep server/simpleserver.py）。"""
    try:
        out = subprocess.run(
            ["pgrep", "-f", STRATEGY_PROCESS_PATTERN],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode != 0 or not out.stdout.strip():
            return []
        return [int(x) for x in out.stdout.strip().split() if x.isdigit()]
    except (FileNotFoundError, subprocess.TimeoutExpired, ValueError):
        return []


def start() -> dict:
    """启动管控进程：nohup python server/simpleserver.py > simpleserverYYYYMMDD.log &"""
    root = _project_root()
    script = _strategy_script_path()
    log_path = root / _log_name()

    if not script.exists():
        return {"ok": False, "error": f"脚本不存在: {script}"}

    pids = _find_pids()
    if pids:
        return {"ok": False, "error": "进程已在运行", "pids": pids}

    try:
        # 使用 server/simpleserver.py 便于 ps -ef | grep server/simpleserver.py 区分
        rel_script = str(Path(CONTROLLED_SCRIPT))
        rel_log = _log_name()
        cmd = f"nohup python3 {rel_script} > {rel_log} 2>&1 &"
        subprocess.run(
            cmd,
            cwd=str(root),
            shell=True,
            timeout=5,
        )
        import time
        time.sleep(0.5)
        pids = _find_pids()
        return {
            "ok": True,
            "message": "策略已启动",
            "log_file": str(log_path),
            "pids": pids,
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}


def stop() -> dict:
    """停止管控进程：对匹配 server/simpleserver.py 的进程执行 kill -9。"""
    pids = _find_pids()
    if not pids:
        return {"ok": True, "message": "策略未在运行", "killed": []}

    killed = []
    for pid in pids:
        try:
            subprocess.run(["kill", "-9", str(pid)], check=True, timeout=3)
            killed.append(pid)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
            pass
    return {"ok": True, "message": "策略已停止", "killed": killed}


def restart() -> dict:
    """重启：先 stop 再 start。"""
    stop_result = stop()
    if not stop_result.get("ok"):
        return stop_result
    import time
    time.sleep(0.5)
    return start()


def status() -> dict:
    """查询策略运行状态。"""
    pids = _find_pids()
    script = _strategy_script_path()
    return {
        "ok": True,
        "running": len(pids) > 0,
        "pids": pids,
        "script_exists": script.exists(),
        "script_path": str(script),
    }
