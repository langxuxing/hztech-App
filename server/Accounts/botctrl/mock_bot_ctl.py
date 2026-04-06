# -*- coding: utf-8 -*-
"""
模拟交易机器人脚本核心：供 botctrl 下各 .sh 调用（Account_List 的 script_file，如 botctrl/xxx.sh）。

子命令：
  start         前台常驻（exec），供 tradingbot_ctrl 跟踪 PID；写日志
  stop          结束进程（读 .pid），写日志
  restart       先 stop 再 exec start
  checkhealth   打印 JSON：运行状态、未结束赛季等；写日志
  season-start  日志 + JSON（bot_seasons 由服务端 POST /season-start 在脚本成功后写入）
  season-stop   日志 + JSON（停赛写库由服务端 POST /season-stop 完成）

环境变量：
  HZTECH_ACCOUNT_ID  必填，对应 account_id
  HZTECH_MOCK_SCRIPT 可选，shell 脚本名（用于日志区分）
"""
from __future__ import annotations

import json
import os
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BOTCTRL_DIR = Path(__file__).resolve().parent
ACCOUNTS_DIR = BOTCTRL_DIR.parent
SERVER_DIR = ACCOUNTS_DIR.parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))


def _safe_pid_tag(account_id: str) -> str:
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in account_id)


def _pid_path(account_id: str) -> Path:
    d = ACCOUNTS_DIR / ".bot_run"
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{_safe_pid_tag(account_id)}.pid"


def _ts_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _account_id_required() -> str:
    aid = (os.environ.get("HZTECH_ACCOUNT_ID") or "").strip()
    if not aid:
        print("ERROR: set HZTECH_ACCOUNT_ID", file=sys.stderr)
        sys.exit(1)
    return aid


def _script_label() -> str:
    return (os.environ.get("HZTECH_MOCK_SCRIPT") or "mock_bot_ctl.py").strip()


def _import_db():
    import db as _db

    _db.init_db()
    return _db


def _import_account_mgr():
    from Accounts import AccountMgr as _am

    return _am


def _initial_capital_from_list(account_id: str) -> float:
    am = _import_account_mgr()
    for row in am.load_account_list():
        if str(row.get("account_id") or "").strip() != account_id:
            continue
        v = row.get("Initial_capital")
        if v is None:
            v = row.get("initial_capital")
        try:
            return float(v) if v is not None else 0.0
        except (TypeError, ValueError):
            return 0.0
    return 0.0


def _equity_for_season(db, account_id: str) -> float:
    snap = db.account_snapshot_latest_by_account(account_id)
    if snap:
        return float(snap["equity_usdt"])
    return _initial_capital_from_list(account_id)


def _cash_for_season(db, account_id: str) -> float:
    snap = db.account_snapshot_latest_by_account(account_id)
    if snap:
        return float(snap["cash_balance"])
    return 0.0


def _pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _read_pids_from_file(account_id: str) -> list[int]:
    pf = _pid_path(account_id)
    if not pf.is_file():
        return []
    try:
        raw = pf.read_text(encoding="utf-8").strip()
    except OSError:
        return []
    out: list[int] = []
    for line in raw.splitlines():
        line = line.strip()
        if line.isdigit():
            out.append(int(line))
    return out


def _write_pid_file(account_id: str, pid: int) -> None:
    try:
        _pid_path(account_id).write_text(f"{pid}\n", encoding="utf-8")
    except OSError:
        pass


def cmd_start() -> None:
    """前台阻塞：模拟策略进程；tradingbot_ctrl 用 $! 跟踪本 PID。"""
    db = _import_db()
    aid = _account_id_required()
    label = _script_label()
    db.log_insert(
        "INFO",
        f"mock_bot start (worker entering loop) account={aid}",
        "mock_bot",
        extra={
            "account_id": aid,
            "script": label,
            "action": "start",
            "ts": _ts_utc(),
        },
    )

    pid = os.getpid()
    _write_pid_file(aid, pid)
    # stderr 进入 tradingbot 的 nohup 日志，便于查看启动状态（stdout 留给控制器解析 PID 时需注意）
    print(
        json.dumps(
            {
                "ok": True,
                "action": "start",
                "account_id": aid,
                "pid": pid,
                "script": label,
                "message": "mock worker running (idle loop)",
            },
            ensure_ascii=False,
        ),
        file=sys.stderr,
        flush=True,
    )

    def _on_signal(signum: int, frame: object) -> None:
        try:
            db2 = _import_db()
            db2.log_insert(
                "INFO",
                f"mock_bot worker signal exit account={aid} signum={signum}",
                "mock_bot",
                extra={"account_id": aid, "script": label, "action": "worker_signal"},
            )
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    while True:
        time.sleep(600)


def cmd_stop() -> int:
    db = _import_db()
    aid = _account_id_required()
    label = _script_label()
    pids = _read_pids_from_file(aid)
    killed: list[int] = []
    for pid in pids:
        if not _pid_is_alive(pid):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
            killed.append(pid)
        except ProcessLookupError:
            pass
    time.sleep(1.0)
    for pid in pids:
        if _pid_is_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    try:
        pf = _pid_path(aid)
        if pf.exists():
            pf.unlink()
    except OSError:
        pass

    db.log_insert(
        "INFO",
        f"mock_bot stop account={aid} killed={killed}",
        "mock_bot",
        extra={
            "account_id": aid,
            "script": label,
            "action": "stop",
            "pids": killed,
            "ts": _ts_utc(),
        },
    )
    print(
        json.dumps(
            {
                "ok": True,
                "action": "stop",
                "account_id": aid,
                "killed_pids": killed,
            },
            ensure_ascii=False,
        ),
        file=sys.stderr,
        flush=True,
    )
    return 0


def cmd_restart() -> None:
    cmd_stop()
    os.execv(sys.executable, [sys.executable, str(Path(__file__).resolve()), "start"])


def cmd_checkhealth() -> int:
    db = _import_db()
    aid = _account_id_required()
    label = _script_label()
    pids = _read_pids_from_file(aid)
    running = any(_pid_is_alive(p) for p in pids)
    seasons = db.bot_season_list_by_bot(aid, limit=5)
    open_season = None
    for s in seasons:
        if s.get("stopped_at") is None:
            open_season = s
            break
    payload = {
        "ok": True,
        "account_id": aid,
        "script": label,
        "running": running,
        "pid_file_pids": pids,
        "open_season": open_season,
        "checked_at": _ts_utc(),
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    db.log_insert(
        "INFO",
        f"mock_bot checkhealth account={aid} running={running}",
        "mock_bot",
        extra={
            "account_id": aid,
            "script": label,
            "action": "checkhealth",
            "running": running,
            "open_season_id": open_season["id"] if open_season else None,
        },
    )
    return 0


def cmd_season_start() -> int:
    """赛季写库由服务端 POST season-start 在脚本成功后统一执行；此处仅日志/JSON，避免与 API 重复入库。"""
    db = _import_db()
    aid = _account_id_required()
    label = _script_label()
    ts = _ts_utc()
    eq = _equity_for_season(db, aid)
    cash = _cash_for_season(db, aid)
    db.log_insert(
        "INFO",
        f"mock_bot season_start account={aid} initial_equity={eq} (db by API)",
        "mock_bot",
        extra={
            "account_id": aid,
            "script": label,
            "action": "season_start",
            "initial_balance": eq,
            "ts": ts,
        },
    )
    print(
        json.dumps(
            {
                "ok": True,
                "action": "season_start",
                "account_id": aid,
                "started_at": ts,
                "initial_balance": eq,
                "initial_cash": cash,
            },
            ensure_ascii=False,
        )
    )
    return 0


def cmd_season_stop() -> int:
    db = _import_db()
    aid = _account_id_required()
    label = _script_label()
    ts = _ts_utc()
    eq = _equity_for_season(db, aid)
    cash = _cash_for_season(db, aid)
    db.log_insert(
        "INFO",
        f"mock_bot season_stop account={aid} final_equity={eq} (db by API)",
        "mock_bot",
        extra={
            "account_id": aid,
            "script": label,
            "action": "season_stop",
            "final_balance": eq,
            "ts": ts,
        },
    )
    print(
        json.dumps(
            {
                "ok": True,
                "action": "season_stop",
                "account_id": aid,
                "stopped_at": ts,
                "final_balance": eq,
                "final_cash": cash,
            },
            ensure_ascii=False,
        )
    )
    return 0


def main() -> None:
    if len(sys.argv) < 2:
        print(
            "usage: mock_bot_ctl.py start|stop|restart|checkhealth|season-start|season-stop",
            file=sys.stderr,
        )
        sys.exit(1)
    cmd = sys.argv[1].strip().lower().replace("_", "-")

    if cmd == "start":
        cmd_start()
        return
    if cmd == "stop":
        raise SystemExit(cmd_stop())
    if cmd == "restart":
        cmd_restart()
        return
    if cmd in ("checkhealth", "health", "status"):
        raise SystemExit(cmd_checkhealth())
    if cmd in ("season-start", "seasonstart"):
        raise SystemExit(cmd_season_start())
    if cmd in ("season-stop", "seasonstop"):
        raise SystemExit(cmd_season_stop())

    print(f"unknown command: {sys.argv[1]}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
