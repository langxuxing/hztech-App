# -*- coding: utf-8 -*-
"""交易机器人进程管控：
- 旧版：baasapi/simpleserver-lhg.py、simpleserver-hztech.py（nohup python3）
- Account_List：script_file 指向 accounts 下可解析的 .sh，通过 `bash script start|stop|restart|status`
  与 `bash script --season start|stop` 管控；PID 写入 accounts/.bot_run/<account_id>.pid。

环境变量：
- MOBILEAPP_ROOT：部署根目录（与 _project_root 一致）。
- HZTECH_TRADINGBOT_CTRL_DIR：策略 shell 所在目录。未设置时默认为
  `<accounts>/tradingbot_ctrl`（即 `baasapi/accounts/tradingbot_ctrl`，例如本机
  `/Volumes/HZTech/hztechApp/baasapi/accounts/tradingbot_ctrl`）。
  `baasapi/run_local.sh` 会显式设为 `$MOBILEAPP_ROOT/baasapi/accounts/tradingbot_ctrl`。
  AWS：`aws-ops/code/install_on_aws.sh`、`aws-ops/aws_ops.sh` 与 `server_mgr` 远端重启缺省为 `/home/ec2-user/Alpha`
  （本机执行部署时勿把 Mac 上的 CTRL_DIR 传到 EC2；若需改远端目录，用环境变量
  `HZTECH_REMOTE_TRADINGBOT_CTRL_DIR`）。
  可为相对路径（相对 accounts 目录）或绝对路径。
  script_file 可为 `tradingbot_ctrl/xxx.sh`、`xxx.sh` 或任意相对 accounts 的子路径；
  解析时会尝试 accounts 根路径与上述目录的组合，取首个存在的文件。
- HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE：json（默认，读 Account_List.json）或 database（读库表 account_list，与 JSON 字段一致，供生产以库为准）。
  AWS 部署脚本与 `server_mgr` 远端重启缺省为 database；覆盖远端可用 `HZTECH_REMOTE_TRADINGBOT_ACCOUNT_LIST_SOURCE`。
- 账户未配置 script_file 时，启停统一缺省使用 `moneyflow_alangsandbox.sh`，避免误指缺失脚本。
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

# bot_id -> 管控脚本相对路径（相对于部署根目录）
BOT_SCRIPTS = {
    "simpleserver-lhg": "baasapi/simpleserver-lhg.py",
    "simpleserver-hztech": "baasapi/simpleserver-hztech.py",
}
# 停止时先 SIGTERM 等待秒数，再对剩余进程 kill -9
STOP_GRACEFUL_WAIT_SEC = 3
# Account_List / account_list 中 script_file 为空时的缺省启动脚本（须在 HZTECH_TRADINGBOT_CTRL_DIR 下存在）
DEFAULT_ACCOUNT_SCRIPT_FILE = "moneyflow_alangsandbox.sh"


def _project_root() -> Path:
    """部署根目录：优先环境变量 MOBILEAPP_ROOT，否则取 baasapi 上一级。"""
    root = os.environ.get("MOBILEAPP_ROOT")
    if root:
        return Path(root)
    return Path(__file__).resolve().parent.parent


def _safe_pid_tag(account_id: str) -> str:
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in account_id)


def effective_account_script_file(stored: str) -> str:
    """返回实际用于解析路径的 script_file；空则 DEFAULT_ACCOUNT_SCRIPT_FILE。"""
    s = (stored or "").strip()
    return s if s else DEFAULT_ACCOUNT_SCRIPT_FILE


def tradingbot_ctrl_dir() -> Path:
    """策略脚本目录：HZTECH_TRADINGBOT_CTRL_DIR，未设置则 accounts/tradingbot_ctrl。"""
    from accounts import AccountMgr as _am

    raw = (os.environ.get("HZTECH_TRADINGBOT_CTRL_DIR") or "").strip()
    if raw:
        p = Path(raw).expanduser()
        if not p.is_absolute():
            p = (_am.ACCOUNTS_DIR / p).resolve()
        else:
            p = p.resolve()
        return p
    return (_am.ACCOUNTS_DIR / "tradingbot_ctrl").resolve()


def resolve_account_script_file(script_file: str) -> Path | None:
    """将 Account_List 的 script_file 解析为实际 .sh 路径；找不到则 None。"""
    from accounts import AccountMgr as _am

    sf = (script_file or "").strip()
    if not sf:
        return None
    if ".." in Path(sf).parts:
        return None

    accounts_root = _am.ACCOUNTS_DIR.resolve()
    ctrl = tradingbot_ctrl_dir()

    candidates: list[Path] = []
    candidates.append((accounts_root / sf).resolve())

    rel = sf[len("tradingbot_ctrl/") :] if sf.startswith("tradingbot_ctrl/") else sf
    candidates.append((ctrl / rel).resolve())

    if "/" not in sf.replace("\\", "/"):
        only = Path(sf).name
        only_path = (ctrl / only).resolve()
        if only_path not in candidates:
            candidates.append(only_path)

    seen: set[Path] = set()
    for i, p in enumerate(candidates):
        if p in seen:
            continue
        seen.add(p)
        if not p.is_file():
            continue
        try:
            if i == 0:
                p.relative_to(accounts_root)
            else:
                p.relative_to(ctrl)
        except ValueError:
            continue
        return p
    return None


def load_account_shell_map() -> dict[str, Path]:
    """已启用账户且脚本可解析 -> 绝对路径（列表来源见 HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE）。"""
    from accounts import AccountMgr as _am

    out: dict[str, Path] = {}
    for basic in _am.list_account_basics_for_tradingbot(enabled_only=True):
        aid = (basic.get("account_id") or "").strip()
        if not aid:
            continue
        sf = effective_account_script_file(basic.get("script_file") or "")
        p = resolve_account_script_file(sf)
        if p is not None:
            out[aid] = p
    return out


def controllable_bot_ids() -> set[str]:
    """可与 POST /api/tradingbots/{id}/start|stop 交互的 bot_id 集合。"""
    return set(BOT_SCRIPTS.keys()) | set(load_account_shell_map().keys())


def is_running(bot_id: str) -> bool:
    """当前进程是否视为在运行（shell 账户读 .pid；旧版 bot 用 pgrep）。"""
    bid = (bot_id or "").strip()
    if not bid:
        return False
    shell_map = load_account_shell_map()
    if bid in shell_map:
        return len(_find_pids_shell(bid)) > 0
    if bid in BOT_SCRIPTS:
        return len(_find_pids(bid)) > 0
    return False


def _pid_file(account_id: str) -> Path:
    from accounts import AccountMgr as _am

    d = _am.ACCOUNTS_DIR / ".bot_run"
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{_safe_pid_tag(account_id)}.pid"


def _pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


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


def _find_pids_shell(account_id: str) -> list[int]:
    """通过 .pid 文件判断 shell 策略是否仍在运行。"""
    pf = _pid_file(account_id)
    if not pf.exists():
        return []
    try:
        raw = pf.read_text(encoding="utf-8").strip()
    except OSError:
        return []
    pids: list[int] = []
    for line in raw.splitlines():
        line = line.strip()
        if line.isdigit():
            pids.append(int(line))
    alive = [p for p in pids if _pid_is_alive(p)]
    if not alive and pids:
        try:
            pf.unlink()
        except OSError:
            pass
    return alive


def start_shell_bot(account_id: str, script_abs: Path, *, force: bool = False) -> dict:
    """`bash script start`，PID 写入 accounts/.bot_run。force=True 时先 stop 再启动。"""
    root = _project_root()
    if not script_abs.is_file():
        return {"ok": False, "error": f"脚本不存在: {script_abs}"}

    pf = _pid_file(account_id)
    existing = _find_pids_shell(account_id)
    if existing and force:
        stop_shell_bot(account_id, script_abs)
        existing = _find_pids_shell(account_id)
    if existing:
        return {"ok": False, "error": "进程已在运行", "pids": existing}

    log_dir = root / "baasapi" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    safe_id = _safe_pid_tag(account_id)
    log_path = log_dir / f"account_{safe_id}_{ts}.log"
    cmd = (
        f'nohup env HZTECH_ACCOUNT_ID="{account_id}" bash "{script_abs}" start '
        f'>> "{log_path}" 2>&1 & echo $!'
    )
    try:
        r = subprocess.run(
            cmd,
            shell=True,
            cwd=str(root),
            capture_output=True,
            text=True,
            timeout=25,
        )
    except Exception as e:
        return {"ok": False, "error": str(e)}

    out = (r.stdout or "").strip()
    last_line = out.splitlines()[-1] if out else ""
    try:
        main_pid = int(last_line.strip())
    except ValueError:
        return {
            "ok": False,
            "error": f"启动失败，未获取 PID。请查看日志: {log_path}",
        }

    time.sleep(0.45)
    if not _pid_is_alive(main_pid):
        return {
            "ok": False,
            "error": f"进程已退出，请检查脚本与日志: {log_path}",
        }

    try:
        pf.write_text(f"{main_pid}\n", encoding="utf-8")
    except OSError as e:
        return {"ok": False, "error": f"无法写入 PID 文件: {e}"}

    return {
        "ok": True,
        "message": "策略已启动",
        "log_file": str(log_path),
        "pids": [main_pid],
    }


def stop_shell_bot(account_id: str, script_abs: Path) -> dict:
    """先执行 `bash script stop`，再清理 .pid 中仍存活的进程。"""
    root = _project_root()
    if not script_abs.is_file():
        return {"ok": False, "error": f"脚本不存在: {script_abs}"}

    env = os.environ.copy()
    env["HZTECH_ACCOUNT_ID"] = account_id
    try:
        subprocess.run(
            ["bash", str(script_abs), "stop"],
            cwd=str(root),
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except Exception:
        pass

    time.sleep(STOP_GRACEFUL_WAIT_SEC)
    pf = _pid_file(account_id)
    killed: list[int] = []
    pids: list[int] = []
    if pf.exists():
        try:
            raw = pf.read_text(encoding="utf-8").strip()
            for line in raw.splitlines():
                line = line.strip()
                if line.isdigit():
                    pids.append(int(line))
        except OSError:
            pass

    for pid in pids:
        if not _pid_is_alive(pid):
            continue
        try:
            subprocess.run(["kill", "-15", str(pid)], check=False, timeout=2)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
    time.sleep(STOP_GRACEFUL_WAIT_SEC)
    for pid in pids:
        if _pid_is_alive(pid):
            try:
                subprocess.run(["kill", "-9", str(pid)], check=True, timeout=3)
                killed.append(pid)
            except (
                subprocess.CalledProcessError,
                subprocess.TimeoutExpired,
                FileNotFoundError,
            ):
                pass

    try:
        if pf.exists():
            pf.unlink()
    except OSError:
        pass

    return {"ok": True, "message": "策略已停止", "killed": killed}


def shell_script_status_json(account_id: str, script_abs: Path) -> dict | None:
    """执行 `bash script status`，解析 stdout：JSON 或单行 running|stopped（失败返回 None）。"""
    root = _project_root()
    if not script_abs.is_file():
        return None
    env = os.environ.copy()
    env["HZTECH_ACCOUNT_ID"] = account_id
    try:
        r = subprocess.run(
            ["bash", str(script_abs), "status"],
            cwd=str(root),
            env=env,
            capture_output=True,
            text=True,
            timeout=45,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    text = (r.stdout or "").strip()
    if not text and r.stderr:
        text = (r.stderr or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        for line in reversed(text.splitlines()):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    line = text.strip().splitlines()[-1].strip().lower() if text else ""
    if line == "running":
        return {"ok": True, "running": True}
    if line == "stopped":
        return {"ok": True, "running": False}
    return None


def start(bot_id: str, *, force: bool = False) -> dict:
    """启动指定 bot 进程。force=True 时对已在运行进程先 stop 再拉起。"""
    shell_map = load_account_shell_map()
    if bot_id in shell_map:
        return start_shell_bot(bot_id, shell_map[bot_id], force=force)

    if bot_id not in BOT_SCRIPTS:
        return {"ok": False, "error": f"未知 bot_id: {bot_id}"}
    root = _project_root()
    script = _script_path(bot_id)
    if not script or not script.exists():
        return {"ok": False, "error": f"脚本不存在: {script}"}
    pids = _find_pids(bot_id)
    if pids:
        if force:
            stop(bot_id)
            time.sleep(0.5)
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
    """停止指定 bot 进程：先 SIGTERM 再 kill -9；shell 账户走 stop_shell_bot。"""
    shell_map = load_account_shell_map()
    if bot_id in shell_map:
        return stop_shell_bot(bot_id, shell_map[bot_id])

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
        except (
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            FileNotFoundError,
        ):
            pass
    return {"ok": True, "message": "策略已停止", "killed": killed}


def restart(bot_id: str) -> dict:
    """重启指定 bot：先 stop 再 start。"""
    stop_result = stop(bot_id)
    if not stop_result.get("ok"):
        return stop_result
    time.sleep(0.5)
    return start(bot_id)


def run_shell_season_action(account_id: str, script_abs: Path, season_sub: str) -> dict:
    """同步执行 `bash script --season start|stop`（日志/JSON；赛季写库由 API 侧 account_season_* 完成）。"""
    root = _project_root()
    if not script_abs.is_file():
        return {"ok": False, "error": f"脚本不存在: {script_abs}"}
    sub = (season_sub or "").strip().lower()
    if sub not in ("start", "stop"):
        return {"ok": False, "error": f"无效赛季子命令: {season_sub!r}"}
    env = os.environ.copy()
    env["HZTECH_ACCOUNT_ID"] = account_id
    try:
        r = subprocess.run(
            ["bash", str(script_abs), "--season", sub],
            cwd=str(root),
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "赛季脚本执行超时"}
    except Exception as e:
        return {"ok": False, "error": str(e)}
    if r.returncode != 0:
        err = (r.stderr or r.stdout or "").strip() or f"退出码 {r.returncode}"
        return {"ok": False, "error": err[-800:]}
    return {"ok": True, "message": "已执行"}


def season_start(bot_id: str) -> dict:
    """盈利赛季开启：需 script 支持 `--season start`（兼容旧 season-start）。"""
    shell_map = load_account_shell_map()
    if bot_id in shell_map:
        return run_shell_season_action(bot_id, shell_map[bot_id], "start")
    if bot_id in BOT_SCRIPTS:
        return {
            "ok": False,
            "error": "该 bot 未配置 accounts script_file，暂不支持 API 赛季操作",
        }
    return {"ok": False, "error": f"未知 bot_id: {bot_id}"}


def season_stop(bot_id: str) -> dict:
    """盈利赛季结束：需 script 支持 `--season stop`（兼容旧 season-stop）。"""
    shell_map = load_account_shell_map()
    if bot_id in shell_map:
        return run_shell_season_action(bot_id, shell_map[bot_id], "stop")
    if bot_id in BOT_SCRIPTS:
        return {
            "ok": False,
            "error": "该 bot 未配置 accounts script_file，暂不支持 API 赛季操作",
        }
    return {"ok": False, "error": f"未知 bot_id: {bot_id}"}


def status() -> dict:
    """查询各 bot 运行状态。返回 bots[bot_id] 含 running:bool、status:\"running\"|\"stopped\"、pids 等。"""
    bots_status: dict = {}
    for bid in BOT_SCRIPTS:
        pids = _find_pids(bid)
        script = _script_path(bid)
        running = len(pids) > 0
        bots_status[bid] = {
            "running": running,
            "status": "running" if running else "stopped",
            "pids": pids,
            "script_exists": script.exists() if script else False,
            "script_path": str(script) if script else "",
        }
    for aid, script in load_account_shell_map().items():
        pids = _find_pids_shell(aid)
        running_pid = len(pids) > 0
        row: dict = {
            "running": running_pid,
            "pids": pids,
            "script_exists": script.is_file(),
            "script_path": str(script),
        }
        rep = shell_script_status_json(aid, script)
        if isinstance(rep, dict):
            row["status_script"] = rep
            if "running" in rep:
                row["running"] = bool(rep.get("running"))
        row["status"] = "running" if row["running"] else "stopped"
        bots_status[aid] = row
    return {
        "ok": True,
        "bots": bots_status,
    }
