# -*- coding: utf-8 -*-
"""
MobileApp API 服务（部署于 AWS 等）
- API（JSON）：App / Flutter Web 共用，路径 /api/*
- Flutter Web 静态资源由 server/serve_web_static.py 或独立 CDN 托管，不由本进程提供
- 文件端点：GET /download/apk/<name>.apk、GET /res/bg；K 线 JSON：GET /kline/<file>.json

App 所需 API（与 QtraderApi.kt 一致）：
  POST /api/login                 登录，Body: {username, password}，返回 {success, token}
  GET  /api/account-profit        账户盈亏（需 Bearer token）
  GET  /api/tradingbots           交易账户列表（需 Bearer token）
  POST /api/tradingbots/{id}/start|stop|restart|season-start|season-stop（需 Bearer token；season-start 先写 account_season 再按需启动策略进程，再执行赛季脚本；season-stop 仅结束赛季记录，不强制 stop 进程；stop 会写当前未结赛季止期及期末权益/现金）
  GET  /api/tradingbots/{id}/pending-orders | /ticker  当前委托、行情（不入库；id 可为 Account_List 的 account_id）
  GET  /api/tradingbots/{id}/profit-history  收益曲线快照（?limit=&since=，默认近 45 天、最多 15000 条）
  GET  /api/tradingbots/{id}/strategy-daily-efficiency  策略效能：现金/权益收益率%、能效、ATR14 与阈值（?inst_id=&days=）
  GET  /api/tradingbots/{id}/seasons/{season_id}/positions-summary  赛季区间内历史平仓笔数与净盈亏（Account_List）
  GET  /kline/<file>.json  PEPE 等 1m 标记价格 K 线 JSON（写入 flutter_app/web/kline；夜间定时补历史）
  GET  /api/tradingbots/{id}/tradingbot-events  账户启停事件（需 Bearer token）
  GET  /api/logs                  日志查询（需 Bearer token，?limit=100&level=&source=）
  GET  /api/users                 用户列表（仅管理员，含 role、linked_account_ids、full_name、phone）
  POST /api/users                 新建用户（仅管理员）Body: {username, password, role?, linked_account_ids?, full_name?, phone?}
  DELETE /api/users/<id>          删除用户（仅管理员，不可删自己）
  PATCH /api/users/<id>           更新角色/客户绑定/全名/手机（仅管理员）
  POST /api/strategy-analyst/auto-net-test  自动收网测试桩（交易员/管理员/策略分析师，客户不可用）
  GET  /api/me                    当前用户 role、linked_account_ids
  GET  /api/health                服务存活（无需登录，供负载均衡探测）
  GET  /api/app-version           移动端版本策略（无需登录；HZTECH_APP_* 环境变量）
  GET  /api/status                同步状态与周期说明（需登录）
  GET  /api/tradingbots/{id}/position-history  历史仓位分页（入库数据，需登录）
  POST /api/tradingbots/{id}/position-history/sync  手动拉取该账户 OKX 历史仓位（仅管理员）
  POST /api/tradingbots/{id}/balance-snapshot/sync  立即拉取 OKX 余额写入库（account_balance_snapshots / tradingbot_profit_snapshots；仅管理员）
  GET  /api/tradingbots/{id}/open-positions-snapshots  已入库的当前持仓聚合快照（按时间倒序；需登录）
  POST /api/tradingbots/{id}/open-positions-snapshot/sync  立即拉取 OKX 当前持仓写入 account_open_positions_snapshots（仅管理员）
  POST /api/admin/balance-snapshots/sync  全量余额快照同步（与定时任务相同；仅管理员）
  POST /api/admin/balance-snapshots/recompute-profit  按 initial_capital 重算全表 profit_*（权益）与 cash_profit_*（资产余额）（仅管理员）
  POST /api/admin/balance-snapshots/backfill-bills  按 OKX bills-archive 为各启用账户补全缺日 account_balance_snapshots，并在有插入时重算 account_daily_performance（仅管理员）
  GET|POST|PUT|DELETE /api/admin/accounts  Account_List.json + account_list 库表同步（仅管理员）
  POST /api/admin/accounts/{id}/test-connection  测连 OKX + 检查 SWAP/双向持仓/50x 杠杆（仅管理员）；Body 可选 {"auto_configure": true} 在测连成功后调用 OKX 设双向持仓/全仓/多空杠杆后复测
  GET  /api/me/customer-accounts  客户已绑定账户列表与密钥文件是否存在（仅客户）
  PUT  /api/me/customer-accounts/{id}/okx-json  客户上传 OKX 密钥 JSON（须已绑定该 account_id）
  POST /api/me/customer-accounts/{id}/test-connection  客户测连（同管理员）；Body 可选 {"auto_configure": true}
管控：
  GET  /api/strategy/status
  POST /api/strategy/start | stop | restart（需 query bot_id=simpleserver-lhg|simpleserver-hztech）
  GET  /api/okx/info
"""
from __future__ import annotations

import atexit
import hashlib
import json
import logging
import os
import signal
import sys
import time
import threading

try:
    import fcntl
except ImportError:
    fcntl = None  # Windows：无 flock，按单进程处理

from datetime import datetime, timedelta, timezone
from pathlib import Path
from functools import wraps
import jwt
from flask import Flask, abort, jsonify, request, send_file, g

import db as _db
import account_list_store as _account_list_store
import strategy_efficiency as _strategy_efficiency
import kline_web_sync as _kline_web_sync
from accounts import AccountMgr as _account_mgr
from exchange import okx as _okx
from tradingbot_ctrl import (
    start as strategy_start,
    stop as strategy_stop,
    restart as strategy_restart,
    season_start as strategy_season_start,
    season_stop as strategy_season_stop,
    status as strategy_status,
    is_running as strategy_is_running,
    controllable_bot_ids,
)

# #region agent log
_DEBUG_LOG_PATH = "/Volumes/HZTech/hztechApp/.cursor/debug-987b91.log"
_DEBUG_SESSION_ID = "987b91"


def _debug_log(location: str, message: str, data: dict, hypothesis_id: str) -> None:
    try:
        with open(_DEBUG_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(
                json.dumps(
                    {
                        "sessionId": _DEBUG_SESSION_ID,
                        "hypothesisId": hypothesis_id,
                        "location": location,
                        "message": message,
                        "data": data,
                        "timestamp": int(time.time() * 1000),
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
    except Exception:
        pass


# #endregion

app = Flask(__name__)

# 本进程仅承担 API（及 /kline、/download 等）；后台定时任务（账户同步、月初、K 线夜间）由本进程在 leader 锁下启动
_BACKGROUND_SCHEDULERS_ENABLED = True

# Account_List → account_balance_snapshots / account_open_positions_snapshots / account_positions_history 同步周期（秒），默认 300（5 分钟）
try:
    _ACCOUNT_SYNC_INTERVAL_SEC = int(
        os.environ.get("HZTECH_ACCOUNT_SYNC_INTERVAL_SEC", "300").strip()
    )
except ValueError:
    _ACCOUNT_SYNC_INTERVAL_SEC = 300
_ACCOUNT_SYNC_INTERVAL_SEC = max(30, min(_ACCOUNT_SYNC_INTERVAL_SEC, 86400))

# 账户同步定时任务只启动一次，避免开发模式下重复 import / 重复注册导致同一周期跑两遍、日志交错
_account_snapshot_timer_started = False
_account_snapshot_timer_lock = threading.Lock()
_month_open_timer_started = False
_month_open_timer_lock = threading.Lock()
_month_open_last_run_ym: str | None = None

# gunicorn 等多 worker 时仅一个进程启动后台定时器；持有锁的进程须保持文件打开直至退出
_BACKGROUND_SCHEDULER_LEADER_LOCK_FP: object | None = None
# 进程启动时写入：是否抢到了跨进程 leader 锁
_BACKGROUND_SCHEDULER_IS_LEADER: bool | None = None


def _try_acquire_background_scheduler_leader_lock() -> bool:
    """跨进程排他锁：仅 leader 进程启动账户同步 / 月初 / K 线夜间任务。

    无 fcntl 的平台（Windows）视为单进程开发环境，始终返回 True。
    锁目录默认 ``<repo>/.temp-cursor``，可用环境变量 ``HZTECH_BACKGROUND_SCHEDULER_LOCK_DIR`` 覆盖。

    日志里常见 ``INFO:main:``：本文件内 ``app = Flask(__name__)``，模块名为 ``main`` 时
    Flask 的 app.logger 名即为 ``main``；
    多段定时任务日志请用 ``pid``/``ppid``（启动与 ``GET /api/status``）或 ``pgrep -af server/main.py`` 区分进程。
    """
    global _BACKGROUND_SCHEDULER_LEADER_LOCK_FP
    if fcntl is None:
        return True
    lock_dir = Path(
        os.environ.get(
            "HZTECH_BACKGROUND_SCHEDULER_LOCK_DIR",
            str(Path(__file__).resolve().parent.parent / ".temp-cursor"),
        )
    )
    lock_dir.mkdir(parents=True, exist_ok=True)
    lock_path = lock_dir / "hztech_background_scheduler.leader.lock"
    fp = open(lock_path, "a+", encoding="utf-8")
    try:
        fcntl.flock(fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fp.close()
        return False
    _BACKGROUND_SCHEDULER_LEADER_LOCK_FP = fp
    return True


# 策略能效默认标的：market_daily_bars 按此 inst_id 全站共用（与接口默认 inst_id 一致）
_DEFAULT_STRATEGY_EFFICIENCY_INST_ID = "PEPE-USDT-SWAP"

# 进程启动时间（Wall ISO + monotonic 用于 uptime）
_PROCESS_START_WALL = datetime.now(timezone.utc).isoformat()
_PROCESS_START_MONO = time.monotonic()

_SYNC_STATE_LOCK = threading.Lock()
_SYNC_STATE: dict = {
    "last_run_completed_at": None,
    "steps": {
        "balance_snapshots": {"ok": None, "error": None},
        "positions_history": {"ok": None, "error": None},
        "open_positions_snapshots": {"ok": None, "error": None},
    },
    "last_loop_error": None,
}


def _sync_record_step(step: str, ok: bool, err: str | None) -> None:
    with _SYNC_STATE_LOCK:
        bucket = _SYNC_STATE["steps"].setdefault(
            step, {"ok": None, "error": None}
        )
        bucket["ok"] = ok
        bucket["error"] = err


def _sync_mark_completed(loop_err: str | None = None) -> None:
    with _SYNC_STATE_LOCK:
        _SYNC_STATE["last_run_completed_at"] = datetime.now(
            timezone.utc
        ).isoformat()
        _SYNC_STATE["last_loop_error"] = loop_err


def _sync_state_snapshot() -> dict:
    with _SYNC_STATE_LOCK:
        return json.loads(json.dumps(_SYNC_STATE))

# 调试日志：LOG_LEVEL=DEBUG 时输出请求/响应详情（便于排查“收到 HTML 而非 JSON”等）
_LOG_LEVEL = os.environ.get("LOG_LEVEL", "").strip().upper()
# 持仓分段调试：DEBUG_POSITIONS=1 时输出 [持仓-API] / [持仓-OKX] 等日志，便于排查界面→API→OKX 调用链
_DEBUG_POSITIONS = os.environ.get("DEBUG_POSITIONS", "0") == "1"
if _LOG_LEVEL == "DEBUG":
    logging.basicConfig(
        level=logging.DEBUG, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    )
    app.logger.setLevel(logging.DEBUG)
    # Werkzeug 请求日志也开到 DEBUG，方便看每条请求
    logging.getLogger("werkzeug").setLevel(logging.DEBUG)


@app.after_request
def _log_request_if_debug(resp):
    """LOG_LEVEL=DEBUG 时记录请求与响应摘要，便于策略管理页等接口调试。"""
    if _LOG_LEVEL != "DEBUG":
        return resp
    app.logger.debug(
        "%s %s -> %s Content-Type: %s",
        request.method,
        request.path,
        resp.status_code,
        resp.content_type or "",
    )
    if resp.status_code >= 400 or (
        resp.content_type and "html" in (resp.content_type or "").lower()
    ):
        try:
            data = resp.get_data()
            snippet = (
                data.decode("utf-8", errors="replace")[:400]
                if isinstance(data, bytes)
                else str(data)[:400]
            )
            resp.set_data(data)
            if snippet.strip().startswith("<"):
                app.logger.debug(
                    "response 为 HTML 片段（客户端若当 JSON 解析会报错）: %s",
                    snippet[:200],
                )
        except Exception:
            pass
    return resp


def _cors_allow_origin() -> str | None:
    """未设置 HZTECH_CORS_ORIGINS 时为 *；否则仅当请求 Origin 在白名单内时回显该 Origin。"""
    raw = os.environ.get("HZTECH_CORS_ORIGINS", "").strip()
    if not raw:
        return "*"
    allowed = {x.strip() for x in raw.split(",") if x.strip()}
    if not allowed:
        return "*"
    origin = request.headers.get("Origin", "")
    if origin and origin in allowed:
        return origin
    return None


# CORS：允许 Flutter Web / 浏览器跨域请求 API，避免 "Failed to fetch"
@app.after_request
def _add_cors(resp):
    allow = _cors_allow_origin()
    if allow:
        resp.headers["Access-Control-Allow-Origin"] = allow
    resp.headers["Access-Control-Allow-Methods"] = (
        "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    )
    resp.headers["Access-Control-Allow-Headers"] = (
        "Content-Type, Authorization, Accept, Access-Control-Request-Private-Network"
    )
    # Chrome 私有网络访问（PNA）预检：从 localhost 页请求 127.0.0.1 时可能需要
    resp.headers["Access-Control-Allow-Private-Network"] = "true"
    return resp


@app.before_request
def _cors_preflight():
    """OPTIONS 预检请求直接返回 204，响应会经 after_request 带上 CORS 头。"""
    if request.method == "OPTIONS":
        return app.make_response(("", 204))


# 项目根目录（部署根，如 /home/ec2-user/hztechapp）
PROJECT_ROOT = Path(
    os.environ.get("MOBILEAPP_ROOT", Path(__file__).resolve().parent.parent)
)
SERVER_DIR = Path(__file__).resolve().parent
CONFIG_DIR = SERVER_DIR / "accounts"
# APK 所在目录（可放多个版本），默认项目根下 apk/，对应 AWS 上 hztechapp/apk/
APK_DIR = Path(os.environ.get("APK_DIR", str(PROJECT_ROOT / "apk")))
# 资源目录：res 已移至 server/res（密钥、背景图等）
RES_DIR = SERVER_DIR / "res"
# OKX 配置路径（API 脱敏、定时拉取账户余额）：由 okx 模块解析默认路径
OKX_CONFIG_PATH = _okx.get_default_config_path(CONFIG_DIR)
_db.init_db()


def _get_jwt_secret() -> str:
    return os.environ.get(
        "JWT_SECRET", "hztech-mobileapp-secret-change-in-production"
    )


def _get_jwt_exp_days() -> int:
    return int(os.environ.get("JWT_EXP_DAYS", "7"))


def _check_password(username: str, password: str) -> bool:
    pwd_hash = hashlib.sha256(password.encode()).hexdigest()
    return _db.user_check_password(username.strip(), pwd_hash)


def _issue_token(username: str) -> str:
    import datetime

    exp = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
        days=_get_jwt_exp_days()
    )
    return jwt.encode(
        {"sub": username, "exp": exp},
        _get_jwt_secret(),
        algorithm="HS256",
    )


def _verify_token(token: str) -> str | None:
    if not token or not token.strip():
        return None
    try:
        payload = jwt.decode(token.strip(), _get_jwt_secret(), algorithms=["HS256"])
        return payload.get("sub")
    except jwt.InvalidTokenError:
        return None


def require_auth(f):
    """需要 Authorization: Bearer <token>，否则 401。"""

    @wraps(f)
    def wrapped(*args, **kwargs):
        auth = request.headers.get("Authorization")
        token = (auth or "").replace("Bearer ", "").strip() if auth else ""
        username = _verify_token(token)
        if not username:
            # #region agent log
            _debug_log(
                "main.py:require_auth",
                "auth_fail_401",
                {
                    "path": request.path,
                    "has_token": bool(token),
                    "token_len": len(token) if token else 0,
                },
                "H1,H4",
            )
            # #endregion
            return jsonify({"success": False, "message": "未登录或 token 无效"}), 401
        g.current_username = username
        g.current_role = _db.user_get_role(username)
        return f(*args, **kwargs)

    return wrapped


def _role() -> str:
    return (getattr(g, "current_role", None) or "trader").strip().lower()


def _is_customer() -> bool:
    return _role() == "customer"


def _is_trader() -> bool:
    return _role() == "trader"


def _is_admin() -> bool:
    return _role() == "admin"


def _require_admin():
    if _is_admin():
        return None
    return jsonify({"success": False, "message": "需要管理员权限"}), 403


def _sync_account_list_after_list_json_write():
    """Account_List.json 已落盘后同步 SQLite account_list（与 JSON 一致）。"""
    try:
        _account_mgr.sync_account_list_after_account_list_write(_db)
    except Exception:
        logging.exception("Account_List 写入后 account_list 同步失败")
        return jsonify(
            {
                "success": False,
                "message": "JSON 已更新但数据库 account_list 同步失败，请查看服务端日志",
            }
        ), 500
    return None


def _is_strategy_analyst() -> bool:
    return _role() == "strategy_analyst"


def _require_trader_or_admin():
    """策略启停、赛季等：交易员或管理员；客户与策略分析师不可调用。"""
    if _is_trader() or _is_admin():
        return None
    return jsonify({"success": False, "message": "仅交易员或管理员可操作策略启停"}), 403


def _validate_customer_okx_json_body(data: object) -> tuple[dict | None, str | None]:
    """客户上传的密钥文件体：与 accounts/OKX_Api_Key 下 JSON 一致，须含 api.key/secret/passphrase。"""
    if not isinstance(data, dict):
        return None, "请求体须为 JSON 对象"
    api = data.get("api")
    if not isinstance(api, dict):
        return None, "须包含 api 对象（与 QTrader / 本系统密钥 JSON 格式一致）"
    key = (api.get("key") or api.get("apikey") or "").strip()
    secret = (
        (api.get("secret") or api.get("secretkey") or api.get("secret_key") or "")
        .strip()
    )
    passphrase = (api.get("passphrase") or "").strip()
    if not key or not secret or not passphrase:
        return None, "api 内须包含 key、secret、passphrase"
    return data, None


def _okx_account_test_http_response(account_id: str):
    """管理员与客户测连共用：余额 + 账户配置 + 杠杆检查（见 exchange.okx.okx_test_account_full）。

    JSON Body 可选：``{"auto_configure": true}`` — 在测连成功（余额可用）后调用
    ``okx_apply_strategy_trading_defaults``（双向持仓、全仓、按 Account_List symbol 设多空杠杆），再执行一次完整检查。
    """
    aid = (account_id or "").strip()
    row = _account_list_store.get_account(aid)
    if not row:
        return jsonify({"success": False, "message": "未找到"}), 404
    dis = _account_mgr.okx_account_disabled_exchange_reason(aid)
    if dis:
        return jsonify({"success": False, "message": dis}), 400
    path = _account_mgr.resolve_okx_key_write_path(aid)
    if path is None:
        return (
            jsonify(
                {
                    "success": False,
                    "message": "无法解析密钥路径，请检查 Account_List 中 account_key_file",
                }
            ),
            400,
        )
    if not path.is_file():
        return (
            jsonify(
                {
                    "success": False,
                    "message": "密钥文件不存在，请先上传或配置 OKX API JSON",
                }
            ),
            400,
        )
    body_json = request.get_json(silent=True)
    auto_configure = bool(
        isinstance(body_json, dict) and body_json.get("auto_configure")
    )
    sym = str(row.get("symbol") or "").strip()
    payload = _okx.okx_test_account_full(path, sym)
    resp_extra: dict = {}
    if auto_configure:
        resp_extra["auto_configure"] = True
        if not payload.get("success"):
            resp_extra["configure_skipped"] = (
                "测连未成功（如余额接口失败），已跳过自动配置"
            )
        else:
            tl = payload.get("target_leverage")
            try:
                target_lev = float(tl) if tl is not None else 50.0
            except (TypeError, ValueError):
                target_lev = 50.0
            cfg_out = _okx.okx_apply_strategy_trading_defaults(
                path, sym, target_leverage=target_lev
            )
            resp_extra["configure_result"] = cfg_out
            payload = _okx.okx_test_account_full(path, sym, target_leverage=target_lev)
    status = 200 if payload.get("success") else 502
    resp = {
        "success": payload.get("success", False),
        "account_id": aid,
        "balance_summary": payload.get("balance_summary"),
        "message": payload.get("message"),
        "configuration_ok": payload.get("configuration_ok"),
        "configuration_warnings": payload.get("configuration_warnings", []),
        "checks": payload.get("checks", {}),
        "account_config": payload.get("account_config", {}),
        "leverage_info": payload.get("leverage_info"),
        "inst_id_checked": payload.get("inst_id_checked"),
        "target_leverage": payload.get("target_leverage"),
        **resp_extra,
    }
    return jsonify(resp), status


def _require_trader_admin_or_analyst():
    """收网测试等：客户不可调用。"""
    if _is_trader() or _is_admin() or _is_strategy_analyst():
        return None
    return jsonify({"success": False, "message": "客户无权使用此功能"}), 403


def _customer_bot_forbidden(bot_id: str):
    """客户仅可访问已绑定的 account / bot id。"""
    if not _is_customer():
        return None
    bid = (bot_id or "").strip()
    allowed = set(_db.user_get_linked_account_ids(g.current_username))
    if bid in allowed:
        return None
    return jsonify({"success": False, "message": "无权访问该账户"}), 403


def _filter_accounts_for_user(accounts: list[dict]) -> list[dict]:
    if not _is_customer():
        return accounts
    allowed = set(_db.user_get_linked_account_ids(g.current_username))
    if not allowed:
        return []
    out = []
    for a in accounts:
        bid = (a.get("bot_id") or a.get("account_id") or "").strip()
        if bid in allowed:
            out.append(a)
    return out


def _filter_bots_for_user(bots: list[dict]) -> list[dict]:
    if not _is_customer():
        return bots
    allowed = set(_db.user_get_linked_account_ids(g.current_username))
    if not allowed:
        return []
    out = []
    for b in bots:
        tid = (b.get("tradingbot_id") or "").strip()
        if tid in allowed:
            out.append(b)
    return out


def _resolve_okx_config_path(bot_or_account_id: str) -> Path | None:
    """Account_List.json 中 account_id 对应的 OKX 密钥 JSON（server/accounts/）。"""
    return _account_mgr.resolve_okx_config_path(bot_or_account_id)


def _live_equity_cash_for_bot(bot_id: str) -> tuple[float, float]:
    """当前 OKX 权益与 USDT 资产余额 cashBal（赛季起止写 final_cash / initial_cash）。"""
    if _account_mgr.okx_account_disabled_exchange_reason(bot_id):
        return 0.0, 0.0
    path = _resolve_okx_config_path(bot_id)
    if not path or not path.is_file():
        return 0.0, 0.0
    live = _okx.okx_fetch_balance(config_path=path)
    if not live:
        return 0.0, 0.0
    eq = float(live.get("equity_usdt") or live.get("total_eq") or 0.0)
    cash_asset = float(live.get("cash_balance") or 0.0)
    return eq, cash_asset


# 账户信息同步器：从 OKX 交易所读取账户信息并写入数据库
def _job_fetch_account_and_save_snapshots() -> None:
    """定时任务：Account_List 账户写入 account_balance_snapshots（含节流后的 bills-archive 缺日补全、
    必要时对部分账户重算 account_daily_performance）、account_open_positions_snapshots、
    account_positions_history（OKX positions-history；周期末在 AccountMgr 内按历史重算全账户 account_daily_performance）；
    周期由 HZTECH_ACCOUNT_SYNC_INTERVAL_SEC 控制（默认 300 秒）。"""
    try:
        _account_mgr.refresh_all_balance_snapshots(_db, app.logger)
        _sync_record_step("balance_snapshots", True, None)
    except Exception as e:
        _sync_record_step("balance_snapshots", False, str(e))
        _db.log_insert(
            "WARN",
            "account_mgr_snapshot_failed",
            source="timer",
            extra={"error": str(e)},
        )

    try:
        _account_mgr.refresh_all_positions_history(_db, app.logger)
        _sync_record_step("positions_history", True, None)
    except Exception as e:
        _sync_record_step("positions_history", False, str(e))
        _db.log_insert(
            "WARN",
            "account_mgr_positions_history_failed",
            source="timer",
            extra={"error": str(e)},
        )

    try:
        _account_mgr.refresh_all_open_positions_snapshots(_db, app.logger)
        _sync_record_step("open_positions_snapshots", True, None)
    except Exception as e:
        _sync_record_step("open_positions_snapshots", False, str(e))
        _db.log_insert(
            "WARN",
            "account_mgr_open_positions_snapshots_failed",
            source="timer",
            extra={"error": str(e)},
        )

    try:
        _mb_err = _strategy_efficiency.ensure_shared_market_daily_bars(
            _db, _okx, _DEFAULT_STRATEGY_EFFICIENCY_INST_ID
        )
        if _mb_err:
            app.logger.debug(
                "market_daily_bars 未补齐昨日: %s", _mb_err
            )
    except Exception as _e_mdb:
        app.logger.warning("market_daily_bars ensure 异常: %s", _e_mdb)

    _sync_mark_completed(None)


def _start_account_snapshot_timer() -> None:
    """后台线程：按 HZTECH_ACCOUNT_SYNC_INTERVAL_SEC（默认 300）执行 AccountMgr 快照；启动后 30 秒执行第一次。"""
    global _account_snapshot_timer_started
    with _account_snapshot_timer_lock:
        if _account_snapshot_timer_started:
            return
        _account_snapshot_timer_started = True

    def _loop() -> None:
        time.sleep(30)
        while True:
            try:
                app.logger.debug(
                    "账户信息同步器：周期开始 pid=%s thread=%s",
                    os.getpid(),
                    threading.current_thread().name,
                )
                _job_fetch_account_and_save_snapshots()
                app.logger.info(
                    "账户信息同步器：周期完成（间隔=%ss）pid=%s thread=%s",
                    _ACCOUNT_SYNC_INTERVAL_SEC,
                    os.getpid(),
                    threading.current_thread().name,
                )
            except Exception as e:
                _sync_mark_completed(str(e))
                _db.log_insert(
                    "WARN",
                    "账户信息同步器：周期错误",
                    source="timer",
                    extra={"error": str(e)},
                )
            time.sleep(_ACCOUNT_SYNC_INTERVAL_SEC)

    t = threading.Thread(target=_loop, daemon=True)
    t.start()


def _start_account_month_open_timer() -> None:
    """UTC 每月 1 日 00:10 前后写入 account_month_open；每分钟检查，同一自然月只跑一次。"""
    global _month_open_timer_started
    with _month_open_timer_lock:
        if _month_open_timer_started:
            return
        _month_open_timer_started = True

    def _loop() -> None:
        global _month_open_last_run_ym
        time.sleep(45)
        while True:
            try:
                now = datetime.now(timezone.utc)
                if now.day == 1 and now.hour == 0 and 10 <= now.minute <= 15:
                    ym = now.strftime("%Y-%m")
                    if _month_open_last_run_ym != ym:
                        _account_mgr.run_account_month_open_rollover(_db, app.logger)
                        _month_open_last_run_ym = ym
            except Exception as e:
                _db.log_insert(
                    "WARN",
                    "account_month_open_timer_error",
                    source="timer",
                    extra={"error": str(e)},
                )
            time.sleep(60)

    t = threading.Thread(target=_loop, daemon=True)
    t.start()


def _bootstrap_account_month_open_if_needed_on_startup() -> None:
    """启动后延迟执行：若当月 account_month_open 对任一可拉取余额的启用账户缺失，则补写一次。"""
    global _month_open_last_run_ym

    time.sleep(8)
    try:
        if not _account_mgr.account_month_open_missing_current_month(_db):
            return
        ym = datetime.now(timezone.utc).strftime("%Y-%m")
        app.logger.info(
            "account_month_open：当月 %s 数据缺失，启动后补写一次",
            ym,
        )
        _account_mgr.run_account_month_open_rollover(_db, app.logger)
        _month_open_last_run_ym = ym
    except Exception as e:
        _db.log_insert(
            "WARN",
            "account_month_open_bootstrap_failed",
            source="timer",
            extra={"error": str(e)},
        )


# 背景图：server/res/lorenz_butterfly.jpg，通过 /res/bg 访问
BG_IMAGE_FILENAME = "lorenz_butterfly.jpg"


@app.route("/res/bg")
def res_bg():
    """落地页背景图 server/res/lorenz_butterfly.jpg。"""
    path = RES_DIR / BG_IMAGE_FILENAME
    if not path.is_file():
        return "", 404
    return send_file(path, mimetype="image/png", max_age=3600)


@app.route("/download/apk/<filename>")
def download_apk(filename):
    """下载 APK（仅允许 .apk 且位于 APK_DIR 内）。"""
    if not filename.endswith(".apk"):
        return jsonify({"error": "invalid file"}), 400
    path = APK_DIR / filename
    if not path.exists() or not path.is_file():
        return jsonify({"error": "not found"}), 404
    return send_file(path, as_attachment=True, download_name=filename)


@app.route("/", methods=["GET"])
def root_index():
    """API 根路径说明（不提供 Flutter Web SPA）。"""
    return jsonify(
        {
            "service": "hztech-api",
            "health": "/api/health",
            "hint": "Flutter Web 请使用 server/serve_web_static.py 或独立静态托管",
        }
    )


# ---------- API：健康与状态 ----------
@app.route("/api/health", methods=["GET"])
def api_health():
    """无需登录：负载均衡或客户端探测服务是否在线。"""
    return jsonify(
        {
            "ok": True,
            "service": "hztech-api",
            "account_sync_interval_sec": _ACCOUNT_SYNC_INTERVAL_SEC,
            "process_started_at_utc": _PROCESS_START_WALL,
        }
    )


@app.route("/api/app-version", methods=["GET"])
def api_app_version():
    """无需登录：iOS/Android 客户端拉取最低/最新版本号与下载信息。

    环境变量（均为可选；未设置 latest 时客户端不提示「可升级」）：
    - HZTECH_APP_ANDROID_MIN / HZTECH_APP_ANDROID_LATEST
    - HZTECH_APP_ANDROID_APK：APK 文件名，默认 禾正量化-release.apk
    - HZTECH_APP_IOS_MIN / HZTECH_APP_IOS_LATEST
    - HZTECH_APP_IOS_STORE_URL：App Store / TestFlight 公开链接
    """
    apk_name = os.environ.get("HZTECH_APP_ANDROID_APK", "").strip()
    if not apk_name:
        apk_name = "禾正量化-release.apk"
    return jsonify(
        {
            "success": True,
            "android": {
                "min_version": os.environ.get("HZTECH_APP_ANDROID_MIN", "").strip(),
                "latest_version": os.environ.get(
                    "HZTECH_APP_ANDROID_LATEST", ""
                ).strip(),
                "apk_filename": apk_name,
            },
            "ios": {
                "min_version": os.environ.get("HZTECH_APP_IOS_MIN", "").strip(),
                "latest_version": os.environ.get("HZTECH_APP_IOS_LATEST", "").strip(),
                "store_url": os.environ.get("HZTECH_APP_IOS_STORE_URL", "").strip(),
            },
        }
    )


@app.route("/api/status", methods=["GET"])
@require_auth
def api_status():
    """已登录：进程 uptime、Account_List 定时同步各步骤结果与说明。"""
    up = int(time.monotonic() - _PROCESS_START_MONO)
    doc = (
        "后台线程按 HZTECH_ACCOUNT_SYNC_INTERVAL_SEC（默认 300 秒＝5 分钟）从 OKX 拉取 "
        "权益、资产余额(cashBal)、可用保证金、占用写入 account_balance_snapshots，当前持仓聚合写入 "
        "account_open_positions_snapshots，并拉取 positions-history 写入 account_positions_history；"
        "同一周期内会根据 account_positions_history 重算各账户 account_daily_performance（日已实现盈亏等）。"
        "进程启动后约 30 秒首次执行一轮。"
    )
    multi_hint = (
        "若怀疑多套定时任务在跑：在服务器执行 pgrep -af 'server/main.py' 看是否多个 Python 进程；"
        "gunicorn 使用 -w N>1 时每个 worker 一个进程，仅 leader 会跑同步（见 process.background_scheduler_leader）。"
        "本地 ./server/run_local.sh：默认仅 API；联调 Web 时 HZTECH_LOCAL_WEB_STATIC=1 另起 serve_web_static.py。"
    )
    return jsonify(
        {
            "success": True,
            "uptime_seconds": up,
            "account_sync_interval_sec": _ACCOUNT_SYNC_INTERVAL_SEC,
            "sync_documentation": doc,
            "multi_process_troubleshooting": multi_hint,
            "sync": _sync_state_snapshot(),
            "process_started_at_utc": _PROCESS_START_WALL,
            "process": {
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "background_scheduler_leader": _BACKGROUND_SCHEDULER_IS_LEADER,
                "background_schedulers_enabled": _BACKGROUND_SCHEDULERS_ENABLED,
                "server_role": "api_server",
                "app_logger_name": app.logger.name,
            },
        }
    )


# ---------- API：登录（无需 token） ----------
@app.route("/api/login", methods=["POST"])
def api_login():
    """POST JSON: {"username":"xxx","password":"xxx"} -> {"success":true,"token":"jwt"} 或 401。"""
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = (data.get("password") or "").strip()
    if not username or not password:
        _db.log_insert(
            "WARN",
            "login_fail",
            source="login",
            extra={"reason": "missing_username_or_password"},
        )
        return jsonify({"success": False, "message": "请输入用户名和密码"}), 400
    if not _check_password(username, password):
        _db.log_insert(
            "WARN", "login_fail", source="login", extra={"username": username}
        )
        return jsonify({"success": False, "message": "用户名或密码错误"}), 401
    token = _issue_token(username)
    if isinstance(token, bytes):
        token = token.decode()
    _db.log_insert("INFO", "login_ok", source="login", extra={"username": username})
    role = _db.user_get_role(username)
    linked = (
        _db.user_get_linked_account_ids(username) if role == "customer" else []
    )
    return jsonify(
        {
            "success": True,
            "token": token,
            "message": "ok",
            "role": role,
            "linked_account_ids": linked,
        }
    )


@app.route("/api/me", methods=["GET"])
@require_auth
def api_me():
    u = g.current_username
    role = _db.user_get_role(u)
    linked = _db.user_get_linked_account_ids(u) if role == "customer" else []
    return jsonify(
        {
            "success": True,
            "username": u,
            "role": role,
            "linked_account_ids": linked,
        }
    )


@app.route("/api/users", methods=["GET", "POST"])
@require_auth
def api_users():
    """GET：用户列表。POST：新建用户。均仅管理员。"""
    denied = _require_admin()
    if denied:
        return denied
    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        username = str(data.get("username") or "").strip()
        password = str(data.get("password") or "")
        role_s = str(data.get("role") or "trader").strip().lower()
        raw_links = data.get("linked_account_ids")
        links_list: list[str] | None = None
        if raw_links is not None:
            if not isinstance(raw_links, list):
                return jsonify(
                    {"success": False, "message": "linked_account_ids 须为数组"}
                ), 400
            links_list = [str(x).strip() for x in raw_links if str(x).strip()]
        if not username or not password:
            return jsonify(
                {"success": False, "message": "username 与 password 必填"}
            ), 400
        full_name = str(data.get("full_name") or "").strip()[:128] or None
        phone = str(data.get("phone") or "").strip()[:32] or None
        pwd_hash = hashlib.sha256(password.encode()).hexdigest()
        links_for_db: list[str] = []
        if role_s == "customer":
            links_for_db = links_list if links_list is not None else []
        ok = _db.user_create(
            username,
            pwd_hash,
            role=role_s,
            linked_account_ids=links_for_db,
            full_name=full_name or None,
            phone=phone or None,
        )
        if not ok:
            return jsonify({"success": False, "message": "创建失败或用户名已存在"}), 409
        rows = _db.user_list()
        row = next((r for r in rows if str(r.get("username", "")).lower() == username.lower()), None)
        if row is None:
            return jsonify({"success": True, "message": "已创建"})
        return jsonify({"success": True, "user": row})
    rows = _db.user_list()
    return jsonify({"success": True, "users": rows})


@app.route("/api/users/<int:user_id>", methods=["PATCH", "DELETE"])
@require_auth
def api_users_patch(user_id: int):
    """PATCH：更新角色/绑定。DELETE：删除用户。均仅管理员；不可删除当前登录用户。"""
    denied = _require_admin()
    if denied:
        return denied
    row = _db.user_get_by_id(user_id)
    if row is None:
        return jsonify({"success": False, "message": "用户不存在"}), 404
    if request.method == "DELETE":
        my_id = _db.user_id_by_username(g.current_username)
        if my_id is not None and my_id == user_id:
            return jsonify({"success": False, "message": "不可删除当前登录用户"}), 400
        if str(row.get("role") or "").strip().lower() == "admin":
            if _db.user_count_with_role("admin") <= 1:
                return jsonify(
                    {"success": False, "message": "不可删除最后一位管理员"}
                ), 400
        if not _db.user_delete(user_id):
            return jsonify({"success": False, "message": "删除失败"}), 400
        return jsonify({"success": True, "message": "已删除"})
    data = request.get_json(silent=True) or {}
    new_role = data.get("role")
    new_links = data.get("linked_account_ids")
    has_full_name = "full_name" in data
    has_phone = "phone" in data
    if new_role is None and new_links is None and not has_full_name and not has_phone:
        return jsonify({"success": False, "message": "无有效字段"}), 400
    role_s = str(new_role).strip().lower() if new_role is not None else None
    links_list: list[str] | None = None
    if new_links is not None:
        if not isinstance(new_links, list):
            return jsonify({"success": False, "message": "linked_account_ids 须为数组"}), 400
        links_list = [str(x).strip() for x in new_links if str(x).strip()]
    full_name_upd: str | None = None
    if has_full_name:
        full_name_upd = str(data.get("full_name") or "").strip()[:128]
    phone_upd: str | None = None
    if has_phone:
        phone_upd = str(data.get("phone") or "").strip()[:32]
    if new_role is not None and role_s is not None:
        ex_role = str(row.get("role") or "").strip().lower()
        if ex_role == "admin" and role_s != "admin":
            if _db.user_count_with_role("admin") <= 1:
                return jsonify(
                    {
                        "success": False,
                        "message": "不可将最后一位管理员改为其他角色",
                    }
                ), 400
    ok = _db.user_update_profile(
        user_id,
        role=role_s,
        linked_account_ids=links_list,
        full_name=full_name_upd,
        phone=phone_upd,
    )
    if not ok:
        return jsonify({"success": False, "message": "更新失败或数据未变"}), 400
    updated = _db.user_get_by_id(user_id)
    return jsonify({"success": True, "user": updated})


@app.route("/api/strategy-analyst/auto-net-test", methods=["POST"])
@require_auth
def api_strategy_analyst_auto_net_test():
    """自动收网测试桩：仅记录请求；交易员/管理员/策略分析师可调用。"""
    denied = _require_trader_admin_or_analyst()
    if denied:
        return denied
    data = request.get_json(silent=True) or {}
    bot_id = str(data.get("bot_id") or "").strip()
    _db.log_insert(
        "INFO",
        "auto_net_test",
        source="strategy_analyst",
        extra={"username": g.current_username, "bot_id": bot_id or None},
    )
    return jsonify(
        {
            "success": True,
            "message": "测试请求已记录，尚未执行实盘收网；可在此接口对接平仓/撤单逻辑。",
            "bot_id": bot_id or None,
        }
    )


def _collect_accounts_profit() -> list[dict]:
    """与 /api/account-profit 一致：数据来自 Account_List.json（AccountMgr）。"""
    return _account_mgr.collect_accounts_profit_for_api(_db)


# ---------- API：App 所需（与 QtraderApi 一致，需登录） ----------
@app.route("/api/account-profit", methods=["GET"])
@require_auth
def api_account_profit():
    """账户盈亏：OKX 拉取权益、USDT 资产余额(cashBal→balance_usdt)、可用保证金与占用；浮亏 upl；profit_* 为权益相对期初；cash_profit_* 为资产余额相对期初；快照供曲线。"""
    accounts = _filter_accounts_for_user(_collect_accounts_profit())
    return jsonify(
        {
            "success": True,
            "accounts": accounts,
            "total_count": len(accounts),
        }
    )


def _bot_is_controllable(bot_id: str) -> bool:
    """每次调用重新读取 Account_List 与脚本文件，避免热部署脚本后需重启进程。"""
    return bot_id in controllable_bot_ids()


def _collect_tradingbots_list() -> list[dict]:
    """与 /api/tradingbots 一致：数据来自 Account_List.json。"""
    bots = _account_mgr.collect_tradingbots_style_list(strategy_status)
    ctrl = controllable_bot_ids()
    for row in bots:
        bid = (row.get("tradingbot_id") or "").strip()
        row["can_control"] = bid in ctrl
    return bots


# 交易账户列表：Account_List.json（AccountMgr）
@app.route("/api/tradingbots", methods=["GET"])
@require_auth
def api_tradingbots():
    bots = _filter_bots_for_user(_collect_tradingbots_list())
    # #region agent log
    _debug_log(
        "main.py:api_tradingbots",
        "tradingbots_ok",
        {"bot_count": len(bots), "path": request.path},
        "H5",
    )
    # #endregion
    return jsonify(
        {
            "bots": bots,
            "tradingbots": None,
            "total": len(bots),
        }
    )


def _bot_op_response(resp: dict, bot_id: str) -> dict:
    """将 bot_ctrl 返回转为 App BotOperationResponse 格式。"""
    ok = resp.get("ok", False)
    pids = resp.get("pids") or []
    return {
        "success": ok,
        "message": resp.get("message") or resp.get("error"),
        "tradingbot_id": bot_id,
        "status": "running" if ok and pids else "stopped",
    }


@app.route("/api/tradingbots/<bot_id>/start", methods=["POST"])
@require_auth
def api_bot_start(bot_id):
    denied = _require_trader_or_admin()
    if denied:
        return denied
    if not _bot_is_controllable(bot_id):
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    resp = strategy_start(bot_id)
    _db.log_insert(
        "INFO",
        "strategy_start",
        source="api",
        extra={
            "bot_id": bot_id,
            "username": getattr(g, "current_username", None),
            "ok": resp.get("ok"),
        },
    )
    _db.strategy_event_insert(
        bot_id, "start", "manual", getattr(g, "current_username", None)
    )
    if resp.get("ok"):
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        _db.tradingbot_mgr_session_start(bot_id, ts, ts)
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/tradingbots/<bot_id>/stop", methods=["POST"])
@require_auth
def api_bot_stop(bot_id):
    denied = _require_trader_or_admin()
    if denied:
        return denied
    if not _bot_is_controllable(bot_id):
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    resp = strategy_stop(bot_id)
    _db.log_insert(
        "INFO",
        "strategy_stop",
        source="api",
        extra={
            "bot_id": bot_id,
            "username": getattr(g, "current_username", None),
            "ok": resp.get("ok"),
        },
    )
    _db.strategy_event_insert(
        bot_id, "stop", "manual", getattr(g, "current_username", None)
    )
    if resp.get("ok"):
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        _db.tradingbot_mgr_session_stop(bot_id, ts, ts)
        final_eq, final_cash = _live_equity_cash_for_bot(bot_id)
        _db.account_season_update_on_stop(bot_id, ts, final_eq, final_cash)
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/tradingbots/<bot_id>/restart", methods=["POST"])
@require_auth
def api_bot_restart(bot_id):
    denied = _require_trader_or_admin()
    if denied:
        return denied
    if not _bot_is_controllable(bot_id):
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    resp = strategy_restart(bot_id)
    _db.log_insert(
        "INFO",
        "strategy_restart",
        source="api",
        extra={
            "bot_id": bot_id,
            "username": getattr(g, "current_username", None),
            "ok": resp.get("ok"),
        },
    )
    _db.strategy_event_insert(
        bot_id, "restart", "manual", getattr(g, "current_username", None)
    )
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/tradingbots/<bot_id>/season-start", methods=["POST"])
@require_auth
def api_bot_season_start(bot_id):
    denied = _require_trader_or_admin()
    if denied:
        return denied
    if not _bot_is_controllable(bot_id):
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    eq, cash = _live_equity_cash_for_bot(bot_id)
    _db.account_season_roll_forward(bot_id, ts, eq, cash)

    start_resp = None
    if not strategy_is_running(bot_id):
        start_resp = strategy_start(bot_id)
        _db.log_insert(
            "INFO",
            "season_start_auto_start_bot",
            source="api",
            extra={
                "bot_id": bot_id,
                "username": getattr(g, "current_username", None),
                "ok": start_resp.get("ok"),
            },
        )

    shell_resp = strategy_season_start(bot_id)
    _db.log_insert(
        "INFO",
        "season_start_api",
        source="api",
        extra={
            "bot_id": bot_id,
            "username": getattr(g, "current_username", None),
            "shell_ok": shell_resp.get("ok"),
            "start_attempted": start_resp is not None,
            "start_ok": start_resp.get("ok") if start_resp else None,
        },
    )
    if not shell_resp.get("ok"):
        _db.log_insert(
            "WARN",
            "season_start_shell_failed",
            source="api",
            extra={"bot_id": bot_id, "error": shell_resp.get("error")},
        )

    if start_resp is not None and not start_resp.get("ok"):
        return jsonify(
            {
                "success": False,
                "message": start_resp.get("error")
                or start_resp.get("message")
                or "策略启动失败",
                "tradingbot_id": bot_id,
                "status": "stopped",
            }
        )

    _db.strategy_event_insert(
        bot_id,
        "season_start",
        "manual",
        getattr(g, "current_username", None),
    )
    running = strategy_is_running(bot_id)
    return jsonify(
        {
            "success": True,
            "message": shell_resp.get("message") or "赛季已启动",
            "tradingbot_id": bot_id,
            "status": "running" if running else "stopped",
        }
    )


@app.route("/api/tradingbots/<bot_id>/season-stop", methods=["POST"])
@require_auth
def api_bot_season_stop(bot_id):
    """结束当前未结赛季记录；不调用策略 stop（进程可保持运行）。"""
    denied = _require_trader_or_admin()
    if denied:
        return denied
    if not _bot_is_controllable(bot_id):
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    resp = strategy_season_stop(bot_id)
    _db.log_insert(
        "INFO",
        "season_stop_api",
        source="api",
        extra={
            "bot_id": bot_id,
            "username": getattr(g, "current_username", None),
            "ok": resp.get("ok"),
        },
    )
    if resp.get("ok"):
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        eq, cash = _live_equity_cash_for_bot(bot_id)
        _db.account_season_update_on_stop(bot_id, ts, eq, cash)
        _db.strategy_event_insert(
            bot_id,
            "season_stop",
            "manual",
            getattr(g, "current_username", None),
        )
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/tradingbots/<bot_id>/profit-history", methods=["GET"])
@require_auth
def api_bot_profit_history(bot_id):
    """机器人盈利历史（用于收益曲线图），按 snapshot_at 升序。

    Account_List 账户读 account_balance_snapshots；默认仅返回自 ``since``（含）起的快照，
    避免 ORDER BY ASC LIMIT 取到最旧一段导致近月曲线为空。未传 ``since`` 时默认为 UTC 此刻起往前 45 天 00:00:00。
    Query: ``limit`` 最大返回条数（默认 15000，上限 50000）；``since`` ISO8601，如 ``2026-01-01T00:00:00.000Z``。
    """
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    try:
        limit = int(request.args.get("limit", 15000))
    except (TypeError, ValueError):
        limit = 15000
    limit = max(1, min(limit, 50000))

    since = (request.args.get("since") or "").strip()
    if not since:
        since = (
            datetime.now(timezone.utc) - timedelta(days=45)
        ).strftime("%Y-%m-%dT00:00:00.000Z")

    account_ids = {
        x["account_id"] for x in _account_mgr.list_account_basics(enabled_only=False)
    }
    if bot_id in account_ids:
        raw = _db.account_snapshot_query_by_account_since(
            bot_id, since_snapshot_at=since, max_rows=limit
        )
        initial_bal = 0.0
        meta = _db.account_list_get(bot_id)
        if meta:
            initial_bal = float(meta["initial_capital"])
        snapshots = [
            {
                "id": r["id"],
                "bot_id": bot_id,
                "snapshot_at": r["snapshot_at"],
                "initial_balance": initial_bal,
                "current_balance": r["cash_balance"],
                "cash_balance": r["cash_balance"],
                "available_margin": r["available_margin"],
                "used_margin": r["used_margin"],
                "equity_usdt": r["equity_usdt"],
                "profit_amount": r["profit_amount"],
                "profit_percent": r["profit_percent"],
                "cash_profit_amount": r.get("cash_profit_amount", 0),
                "cash_profit_percent": r.get("cash_profit_percent", 0),
                "created_at": r["created_at"],
            }
            for r in raw
        ]
        return jsonify({"success": True, "bot_id": bot_id, "snapshots": snapshots})
    rows = _db.bot_profit_query_by_bot_since(
        bot_id, since_snapshot_at=since, max_rows=limit
    )
    return jsonify({"success": True, "bot_id": bot_id, "snapshots": rows})


@app.route("/api/tradingbots/<bot_id>/strategy-daily-efficiency", methods=["GET"])
@require_auth
def api_strategy_daily_efficiency(bot_id):
    """
    策略效能：每日波动率（|高−低|/收盘%）、现金收益率%（日现金增量/UTC 自然月月初资金×100）、
    策略能效（日增量 USDT÷(波幅×1e9)）；并返回权益日增量、权益收益率%（÷月初权益）、权益能效、
    Wilder ATR(14) 及 0.1/0.6/1.2×ATR 价格阈值（经典 TR，与库字段 tr=|H−L| 不同）。
    日线 OHLC/TR 来自 market_daily_bars 全站缓存。
    现金：Account_List 账户读 account_balance_snapshots（cash_basis 仍为 account_snapshots_cash）；
    其余 bot 读 tradingbot_profit_snapshots 的 equity_usdt 作日权益变动（cash_basis=bot_profit_equity）；
    无任何快照时按 K 线日期补 sod=eod=0、增量 0（cash_basis=none），仍合并计算能效（增量为 0 则能效为 0）。
    Query: inst_id=PEPE-USDT-SWAP&days=31（默认约最近一个月，按 UTC 日）
    """
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    inst_id = (request.args.get("inst_id") or "PEPE-USDT-SWAP").strip()
    try:
        days = int(request.args.get("days", 31))
    except (TypeError, ValueError):
        days = 31
    days = max(7, min(366, days))
    bars, m_err = _strategy_efficiency.load_market_bars_for_efficiency(
        _db, _okx, inst_id, days
    )
    if m_err or not bars:
        return (
            jsonify(
                {
                    "success": False,
                    "message": m_err or "no market data",
                    "inst_id": inst_id,
                }
            ),
            502,
        )

    account_ids = {
        x["account_id"] for x in _account_mgr.list_account_basics(enabled_only=False)
    }
    since_dt = datetime.now(timezone.utc) - timedelta(days=days + 3)
    if bars:
        try:
            day_strs = [str(b.get("day") or "") for b in bars if b.get("day")]
            if day_strs:
                earliest = min(day_strs)
                y, m, _dd = (int(x) for x in earliest.split("-")[:3])
                first_of_m = datetime(y, m, 1, tzinfo=timezone.utc)
                anchor = first_of_m - timedelta(days=40)
                if anchor < since_dt:
                    since_dt = anchor
        except (ValueError, TypeError, IndexError):
            pass
    since = since_dt.strftime("%Y-%m-%dT00:00:00.000Z")

    snaps: list = []
    cash_basis = "none"
    if bot_id in account_ids:
        snaps = _db.account_snapshot_query_by_account_since(
            bot_id, since_snapshot_at=since, max_rows=50000
        )
        cash_basis = "account_snapshots_cash"
    else:
        raw_bot = _db.bot_profit_query_by_bot_since(
            bot_id, since_snapshot_at=since, max_rows=50000
        )
        snaps = _strategy_efficiency.normalize_bot_profit_snapshots_for_efficiency(
            raw_bot
        )
        if snaps:
            cash_basis = "bot_profit_equity"

    cash_by_day = _strategy_efficiency.daily_cash_delta_by_utc_day(snaps)
    cash_by_day = _strategy_efficiency.fill_cash_by_day_for_market_bars(
        bars, cash_by_day
    )

    month_bases = _strategy_efficiency.month_start_cash_by_month_from_snapshots(snaps)

    equity_snaps: list[dict] = []
    for r in snaps:
        ts = str(r.get("snapshot_at") or "")
        if bot_id in account_ids:
            eq = float(r.get("equity_usdt") or 0.0)
        else:
            if r.get("equity_usdt") is not None:
                eq = float(r["equity_usdt"])
            else:
                eq = float(r.get("cash_balance") or 0.0)
        equity_snaps.append({"snapshot_at": ts, "equity_usdt": eq})

    equity_by_day = _strategy_efficiency.daily_equity_delta_by_utc_day(equity_snaps)
    equity_by_day = _strategy_efficiency.fill_equity_by_day_for_market_bars(
        bars, equity_by_day
    )
    month_equity_bases = _strategy_efficiency.month_start_equity_by_month_from_snapshots(
        equity_snaps
    )

    if bot_id in account_ids:
        try:
            day_strs_e = [str(b.get("day") or "") for b in bars if b.get("day")]
            min_ym = min(d[:7] for d in day_strs_e) if day_strs_e else since[:7]
        except (ValueError, TypeError, IndexError):
            min_ym = since[:7]
        mo_map = _db.account_month_open_list_since(bot_id, min_ym)
        for ym, row in mo_map.items():
            ib = row.get("initial_balance")
            if ib is not None and float(ib) > 0:
                month_bases[ym] = float(ib)
            oe = row.get("open_equity")
            if oe is not None and float(oe) > 0:
                month_equity_bases[ym] = float(oe)

    bars_asc = sorted(bars, key=lambda x: str(x.get("day") or ""))
    atr14_by_day = _strategy_efficiency.compute_atr14_wilder_by_day(bars_asc)

    rows = _strategy_efficiency.merge_daily_efficiency_rows(
        bars,
        cash_by_day,
        month_bases or None,
        equity_by_day=equity_by_day,
        month_equity_base_by_month=month_equity_bases or None,
        atr14_by_day=atr14_by_day,
    )
    # merge 会覆盖 span=days+12 的 K 线，行数可能多于请求天数；仅返回最近 days 个 UTC 自然日（merge 已按日倒序）
    if len(rows) > days:
        rows = rows[:days]
    return jsonify(
        {
            "success": True,
            "bot_id": bot_id,
            "inst_id": inst_id,
            "day_basis": "utc",
            "cash_basis": cash_basis,
            "rows": rows,
        }
    )


@app.route("/api/tradingbots/<bot_id>/daily-realized-pnl", methods=["GET"])
@require_auth
def api_bot_daily_realized_pnl(bot_id):
    """
    历史平仓按 UTC 自然日汇总（account_positions_history 的 u_time_ms=OKX uTime 平仓时刻），并与 account_daily_performance 合并。
    额外含 equity_change、cash_change、pnl_pct（相对当月 account_month_open.initial_balance%）、
    equity_base_realized_chain、pnl_pct_realized_chain、benchmark_inst_id、market_tr、efficiency_ratio。
    Query: year=2026&month=4
    """
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    try:
        y = int(request.args.get("year", 0))
        m = int(request.args.get("month", 0))
    except (TypeError, ValueError):
        return jsonify({"success": False, "message": "year/month 无效"}), 400
    if y < 2000 or y > 2100 or m < 1 or m > 12:
        return jsonify({"success": False, "message": "year/month 超出范围"}), 400
    bid = (bot_id or "").strip()
    pos_rows = _db.account_positions_daily_realized(bid, y, m)
    perf_rows = _db.account_daily_performance_query_month(bid, y, m)
    perf_by_day = {str(p["day"]): p for p in perf_rows}
    pos_by_day = {str(r["day"]): r for r in pos_rows}
    all_days = sorted(set(perf_by_day.keys()) | set(pos_by_day.keys()))
    rows: list[dict] = []
    for d in all_days:
        pr = pos_by_day.get(d)
        if pr is not None:
            r = dict(pr)
        else:
            r = {"day": d, "net_pnl": 0.0, "close_count": 0}
        p = perf_by_day.get(d)
        if p:
            r["equity_change"] = p.get("equity_change")
            r["cash_change"] = p.get("cash_change")
            r["pnl_pct"] = p.get("pnl_pct")
            r["equity_base_realized_chain"] = p.get("equity_base_realized_chain")
            r["pnl_pct_realized_chain"] = p.get("pnl_pct_realized_chain")
            r["benchmark_inst_id"] = p.get("benchmark_inst_id")
            r["market_tr"] = p.get("market_tr")
            r["efficiency_ratio"] = p.get("efficiency_ratio")
            r["performance_updated_at"] = p.get("updated_at")
        rows.append(r)
    total = sum(float(r["net_pnl"]) for r in rows)
    return jsonify(
        {
            "success": True,
            "bot_id": bid,
            "year": y,
            "month": m,
            "day_basis": "utc",
            "month_total_pnl": total,
            "days": rows,
        }
    )


@app.route("/api/okx/positions", methods=["GET"])
@require_auth
def api_okx_positions():
    """当前持仓（OKX 实时，全局配置），含数量/持仓成本/当前价 last_px/动态盈亏 upl。"""
    if _is_customer():
        return jsonify(
            {"success": False, "message": "客户无权使用全局持仓接口"}
        ), 403
    positions, err = _okx.okx_fetch_positions(config_path=None)
    return jsonify({"success": True, "positions": positions, "positions_error": err})


@app.route("/api/tradingbots/<bot_id>/positions", methods=["GET"])
@require_auth
def api_bot_positions(bot_id):
    """指定 bot 的当前持仓（按 account_api_file 拉 OKX），含数量、持仓成本、当前价位、动态盈亏。"""
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    if _DEBUG_POSITIONS:
        app.logger.info("[持仓-API] 收到请求 bot_id=%s", bot_id)
    # #region agent log
    _debug_log(
        "main.py:api_bot_positions:entry",
        "positions request",
        {"bot_id": bot_id},
        "H1",
    )
    # #endregion
    dis = _account_mgr.okx_account_disabled_exchange_reason(bot_id)
    if dis:
        return jsonify(
            {
                "success": True,
                "bot_id": bot_id,
                "positions": [],
                "positions_error": dis,
            }
        )
    config_path = _resolve_okx_config_path(bot_id)
    # #region agent log
    _debug_log(
        "main.py:api_bot_positions:config",
        "config resolved",
        {
            "bot_id": bot_id,
            "config_name": config_path.name if config_path else None,
            "config_exists": bool(config_path),
        },
        "H2",
    )
    # #endregion
    app.logger.info(
        "positions bot_id=%s config=%s",
        bot_id,
        config_path.name if config_path else None,
    )
    if not config_path:
        return jsonify(
            {
                "success": True,
                "bot_id": bot_id,
                "positions": [],
                "positions_error": "未找到 OKX 配置：请检查 Account_List.json 中该账户的 account_key_file 与密钥文件",
            }
        )
    positions, positions_error = _okx.okx_fetch_positions(config_path=config_path)
    # #region agent log
    _debug_log(
        "main.py:api_bot_positions",
        "positions_after_okx",
        {
            "bot_id": bot_id,
            "positions_len": len(positions) if positions else 0,
            "positions_error_preview": (positions_error or "")[:120],
        },
        "H2",
    )
    # #endregion
    if not positions and positions_error:
        app.logger.info(
            "positions bot_id=%s result empty (see OKX logs above if auth/network issue)",
            bot_id,
        )
    payload: dict = {
        "success": True,
        "bot_id": bot_id,
        "positions": positions,
        "positions_error": positions_error,
    }
    if positions_error and "1010" in positions_error:
        payload["okx_debug"] = _okx.okx_debug_snapshot(config_path)
    return jsonify(payload)


@app.route("/api/tradingbots/<bot_id>/position-history", methods=["GET"])
@require_auth
def api_bot_position_history(bot_id):
    """已入库的历史平仓记录（OKX positions-history 同步），按更新时间倒序分页。"""
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    try:
        limit = int(request.args.get("limit", 100))
    except (TypeError, ValueError):
        limit = 100
    limit = max(1, min(limit, 500))
    before_raw = request.args.get("before_utime")
    since_raw = request.args.get("since_utime")
    before_utime_ms = None
    since_utime_ms = None
    if before_raw is not None and str(before_raw).strip() != "":
        try:
            before_utime_ms = int(before_raw)
        except (TypeError, ValueError):
            return jsonify(
                {"success": False, "message": "before_utime 无效"}
            ), 400
    if since_raw is not None and str(since_raw).strip() != "":
        try:
            since_utime_ms = int(since_raw)
        except (TypeError, ValueError):
            return jsonify(
                {"success": False, "message": "since_utime 无效"}
            ), 400
    bid = (bot_id or "").strip()
    rows = _db.account_positions_history_query_by_account(
        bid,
        limit=limit,
        before_utime_ms=before_utime_ms,
        since_utime_ms=since_utime_ms,
    )
    next_before = None
    if rows and len(rows) >= limit:
        last_ut = rows[-1].get("u_time_ms")
        if last_ut is not None:
            try:
                next_before = int(last_ut)
            except (TypeError, ValueError):
                next_before = None
    return jsonify(
        {
            "success": True,
            "bot_id": bid,
            "rows": rows,
            "next_before_utime": next_before,
            "has_more": next_before is not None,
        }
    )


@app.route("/api/tradingbots/<bot_id>/position-history/sync", methods=["POST"])
@require_auth
def api_bot_position_history_sync(bot_id):
    """仅管理员：立即从 OKX 拉取该 account_id 的历史仓位并入库。"""
    denied = _require_admin()
    if denied:
        return denied
    bid = (bot_id or "").strip()
    ok, msg = _account_mgr.refresh_positions_history_one(_db, bid, app.logger)
    code = 200 if ok else 400
    return jsonify({"success": ok, "bot_id": bid, "message": msg}), code


@app.route("/api/tradingbots/<bot_id>/balance-snapshot/sync", methods=["POST"])
@require_auth
def api_bot_balance_snapshot_sync(bot_id):
    """
    仅管理员：从 OKX 拉取权益、USDT 资产余额(cashBal)、可用保证金、占用并入库。
    Account_List 账户 → account_balance_snapshots（profit_* = 权益 − account_list.initial_capital）。
    策略效能接口按 UTC 日汇总这些快照计算日现金增量、现金收益率%、策略能效。
    """
    denied = _require_admin()
    if denied:
        return denied
    bid = (bot_id or "").strip()
    dis = _account_mgr.okx_account_disabled_exchange_reason(bid)
    if dis:
        return jsonify({"success": False, "bot_id": bid, "message": dis}), 400
    path = _resolve_okx_config_path(bid)
    if not path or not path.is_file():
        return (
            jsonify(
                {
                    "success": False,
                    "bot_id": bid,
                    "message": "未找到 OKX 配置",
                }
            ),
            400,
        )
    account_ids = {
        x["account_id"] for x in _account_mgr.list_account_basics(enabled_only=False)
    }
    if bid not in account_ids:
        return (
            jsonify(
                {
                    "success": False,
                    "bot_id": bid,
                    "message": "非 Account_List 账户，无法同步余额快照",
                }
            ),
            400,
        )
    ok, msg = _account_mgr.refresh_balance_snapshot_one(_db, bid, app.logger)
    code = 200 if ok else 400
    return jsonify({"success": ok, "bot_id": bid, "message": msg}), code


@app.route("/api/tradingbots/<bot_id>/open-positions-snapshots", methods=["GET"])
@require_auth
def api_bot_open_positions_snapshots(bot_id):
    """已入库的当前持仓聚合快照（按合约；snapshot_at 降序）。Account_List 账户。"""
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    try:
        limit = int(request.args.get("limit", 200))
    except (TypeError, ValueError):
        limit = 200
    limit = max(1, min(limit, 2000))
    inst_raw = (request.args.get("inst_id") or "").strip()
    inst_f = inst_raw if inst_raw else None
    bid = (bot_id or "").strip()
    rows = _db.account_open_positions_snapshots_query_by_account(
        bid, limit=limit, inst_id=inst_f
    )
    return jsonify({"success": True, "bot_id": bid, "rows": rows})


@app.route("/api/tradingbots/<bot_id>/open-positions-snapshot/sync", methods=["POST"])
@require_auth
def api_bot_open_positions_snapshot_sync(bot_id):
    """仅管理员：从 OKX 拉取当前持仓并按合约聚合写入 account_open_positions_snapshots。"""
    denied = _require_admin()
    if denied:
        return denied
    bid = (bot_id or "").strip()
    ok, msg = _account_mgr.refresh_open_positions_snapshot_one(_db, bid, app.logger)
    code = 200 if ok else 400
    return jsonify({"success": ok, "bot_id": bid, "message": msg}), code


@app.route("/api/admin/balance-snapshots/sync", methods=["POST"])
@require_auth
def api_admin_balance_snapshots_sync():
    """仅管理员：对所有启用 Account_List 账户执行一轮余额快照写入（与定时同步任务一致）。"""
    denied = _require_admin()
    if denied:
        return denied
    errors: list[str] = []
    try:
        _account_mgr.refresh_all_balance_snapshots(_db, app.logger)
    except Exception as e:
        errors.append(f"account_balance_snapshots: {e}")
    ok = len(errors) == 0
    return jsonify(
        {
            "success": ok,
            "message": "已完成" if ok else "; ".join(errors),
            "errors": errors,
        }
    ), (200 if ok else 500)


@app.route("/api/admin/balance-snapshots/recompute-profit", methods=["POST"])
@require_auth
def api_admin_balance_snapshots_recompute_profit():
    """仅管理员：按当前 account_list.initial_capital 重算 profit_*（权益）与 cash_profit_*（资产余额）。"""
    denied = _require_admin()
    if denied:
        return denied
    try:
        n = _db.account_balance_snapshots_recompute_profit()
    except Exception as e:
        app.logger.exception("recompute-profit failed")
        return (
            jsonify(
                {
                    "success": False,
                    "message": str(e),
                    "rows_updated": 0,
                }
            ),
            500,
        )
    return jsonify(
        {
            "success": True,
            "message": f"已更新 {n} 条快照行的 profit_amount / profit_percent",
            "rows_updated": n,
        }
    )


@app.route("/api/admin/balance-snapshots/backfill-bills", methods=["POST"])
@require_auth
def api_admin_balance_snapshots_backfill_bills():
    """对 Account_List 启用账户：用 OKX 近 3 月账单中的 USDT 余额补全缺日快照（不覆盖已有日期）。

    可选 JSON Body：``{"days": 40}``，将回看自然日数限制在 7～92（默认 40，约覆盖近一月）。
    若有新插入行，会对相应账户执行 ``account_daily_performance`` 重建（与 positions-history 汇总口径一致）。
    """
    denied = _require_admin()
    if denied:
        return denied
    days = 40
    if request.is_json:
        body = request.get_json(silent=True)
        if isinstance(body, dict) and body.get("days") is not None:
            try:
                days = int(body["days"])
            except (TypeError, ValueError):
                days = 40
    days = max(7, min(92, int(days)))
    total = 0
    details: list[dict] = []
    accounts_adp: list[str] = []
    for row in _account_mgr.list_account_basics(enabled_only=True):
        aid = str(row.get("account_id") or "").strip()
        if not aid:
            continue
        try:
            n, msg = _account_mgr.backfill_account_snapshots_from_okx_bills(
                _db, aid, app.logger, days=days
            )
        except Exception as e:
            details.append({"account_id": aid, "inserted": 0, "message": str(e)})
            continue
        total += n
        if n > 0:
            accounts_adp.append(aid)
        if n or msg:
            details.append({"account_id": aid, "inserted": n, "message": msg})
    if accounts_adp:
        _account_mgr.rebuild_account_daily_performance_safe(
            _db, accounts_adp, app.logger
        )
    return jsonify(
        {
            "success": True,
            "total_inserted": total,
            "accounts": details,
        }
    )


@app.route("/api/tradingbots/<bot_id>/pending-orders", methods=["GET"])
@require_auth
def api_bot_pending_orders(bot_id):
    """当前委托（OKX 实时，不入库）。"""
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    dis = _account_mgr.okx_account_disabled_exchange_reason(bot_id)
    if dis:
        return jsonify(
            {
                "success": True,
                "bot_id": bot_id,
                "orders": [],
                "orders_error": dis,
            }
        )
    config_path = _resolve_okx_config_path(bot_id)
    if not config_path:
        return jsonify(
            {
                "success": True,
                "bot_id": bot_id,
                "orders": [],
                "orders_error": "未找到 OKX 配置",
            }
        )
    orders, err = _okx.okx_fetch_pending_orders(config_path=config_path)
    return jsonify(
        {
            "success": True,
            "bot_id": bot_id,
            "orders": orders,
            "orders_error": err,
        }
    )


@app.route("/api/tradingbots/<bot_id>/ticker", methods=["GET"])
@require_auth
def api_bot_ticker(bot_id):
    """公开行情：query inst_id=BTC-USDT-SWAP（可选 symbol 自 Account_List 默认交易对）。"""
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    inst_id = (request.args.get("inst_id") or "").strip()
    if not inst_id:
        for row in _account_mgr.iter_okx_accounts(enabled_only=True):
            if str(row.get("account_id") or "").strip() == bot_id:
                inst_id = (row.get("symbol") or "").strip()
                break
    if not inst_id:
        return jsonify(
            {"success": False, "bot_id": bot_id, "message": "缺少 inst_id 且账户无默认 symbol"}
        ), 400
    px = _okx.okx_fetch_ticker(inst_id)
    return jsonify(
        {
            "success": px is not None,
            "bot_id": bot_id,
            "inst_id": inst_id,
            "last": px,
        }
    )


def _enrich_season_row(row: dict) -> dict:
    """补充 is_active、duration_seconds 便于前端展示。"""
    out = dict(row)
    stopped = row.get("stopped_at")
    st = stopped is None or (
        isinstance(stopped, str) and not stopped.strip()
    )
    out["is_active"] = bool(st)
    started = row.get("started_at")
    dur = None
    if started and stopped and str(stopped).strip():
        try:
            s = datetime.fromisoformat(
                str(started).replace("Z", "+00:00")
            )
            e = datetime.fromisoformat(
                str(stopped).replace("Z", "+00:00")
            )
            dur = max(0, int((e - s).total_seconds()))
        except (TypeError, ValueError):
            dur = None
    out["duration_seconds"] = dur
    return out


@app.route("/api/tradingbots/<bot_id>/seasons", methods=["GET"])
@require_auth
def api_tradingbot_seasons(bot_id):
    """赛季列表（库表 account_season；响应含 bot_id/account_id 与路径 id 一致）：启停时间、初期权益/现金、盈利。"""
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    limit = min(int(request.args.get("limit", 50)), 100)
    raw = _db.account_season_list_by_account(bot_id, limit=limit)
    rows = [_enrich_season_row(r) for r in raw]
    active_count = sum(1 for r in rows if r.get("is_active"))
    return jsonify(
        {
            "success": True,
            "bot_id": bot_id,
            "account_id": bot_id,
            "seasons": rows,
            "active_season_count": active_count,
        }
    )


def _iso_utc_to_epoch_ms(iso_s: str | None) -> int:
    s = (iso_s or "").strip()
    if not s:
        return 0
    try:
        if s.endswith("Z"):
            dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        else:
            dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp() * 1000)
    except (TypeError, ValueError):
        return 0


@app.route(
    "/api/tradingbots/<bot_id>/seasons/<int:season_id>/positions-summary",
    methods=["GET"],
)
@require_auth
def api_tradingbot_season_positions_summary(bot_id, season_id: int):
    """
    按赛季时间区间汇总 account_positions_history：平仓笔数、净盈亏；
    时间边界与 OKX 一致：按 u_time_ms（接口 uTime，仓位更新时间/平仓时刻），非 cTime；净盈亏同 OKX realizedPnl（库内 realized_pnl，缺省分项相加）。
    仅当路径 id 为 Account_List 中的 account_id 时有数据；否则返回 success 与零值说明。
    """
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    account_ids = {
        x["account_id"] for x in _account_mgr.list_account_basics(enabled_only=False)
    }
    if (bot_id or "").strip() not in account_ids:
        return jsonify(
            {
                "success": True,
                "bot_id": bot_id,
                "season_id": season_id,
                "account_id": bot_id,
                "message": "非 Account_List 账户，无 positions-history 汇总",
                "close_count": 0,
                "net_realized_pnl_usdt": 0.0,
                "u_time_start_ms": None,
                "u_time_end_ms": None,
            }
        )
    sea = _db.account_season_get_by_id(bot_id, season_id)
    if not sea:
        return jsonify({"success": False, "message": "赛季不存在"}), 404
    t0 = _iso_utc_to_epoch_ms(str(sea.get("started_at") or ""))
    if t0 <= 0:
        return jsonify({"success": False, "message": "赛季 started_at 无效"}), 400
    stopped = sea.get("stopped_at")
    if stopped:
        t1 = _iso_utc_to_epoch_ms(str(stopped))
    else:
        t1 = int(datetime.now(timezone.utc).timestamp() * 1000)
    if t1 < t0:
        return jsonify({"success": False, "message": "赛季时间区间无效"}), 400
    agg = _db.account_positions_history_aggregate_u_time_range(bot_id, t0, t1)
    return jsonify(
        {
            "success": True,
            "bot_id": bot_id,
            "season_id": season_id,
            "account_id": bot_id,
            "started_at": sea.get("started_at"),
            "stopped_at": sea.get("stopped_at"),
            "u_time_start_ms": t0,
            "u_time_end_ms": t1,
            "close_count": agg["close_count"],
            "net_realized_pnl_usdt": agg["net_realized_pnl_usdt"],
        }
    )


@app.route("/api/tradingbots/<bot_id>/tradingbot-events", methods=["GET"])
@require_auth
def api_bot_tradingbot_events(bot_id):
    """机器人启停事件记录（手动/自动、时间、操作人）。"""
    denied = _customer_bot_forbidden(bot_id)
    if denied:
        return denied
    limit = min(int(request.args.get("limit", 50)), 200)
    rows = _db.strategy_event_query(bot_id=bot_id, limit=limit)
    return jsonify({"success": True, "bot_id": bot_id, "events": rows})


# ---------- API：策略（Web 管控用，需 query bot_id=simpleserver-lhg|simpleserver-hztech） ----------
@app.route("/api/strategy/status", methods=["GET"])
def api_strategy_status():
    """未带 token 时返回全部 bot 状态（兼容监控/旧测试）；Bearer 为客户时仅返回其 linked_account_ids 对应项。"""
    payload = strategy_status()
    auth = request.headers.get("Authorization") or ""
    token = auth.replace("Bearer ", "").strip() if auth else ""
    if token:
        username = _verify_token(token)
        if username and _db.user_get_role(username) == "customer":
            allowed = set(_db.user_get_linked_account_ids(username))
            bots = payload.get("bots") or {}
            payload = {
                **payload,
                "bots": (
                    {k: v for k, v in bots.items() if k in allowed}
                    if allowed
                    else {}
                ),
            }
    return jsonify(payload)


@app.route("/api/strategy/start", methods=["POST", "GET"])
@require_auth
def api_strategy_start():
    denied = _require_trader_or_admin()
    if denied:
        return denied
    bot_id = (
        request.args.get("bot_id")
        or (request.get_json(silent=True) or {}).get("bot_id")
    ) or ""
    if not _bot_is_controllable(bot_id):
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "缺少或无效的 bot_id（simpleserver-* 或 Account_List 中已配置 script_file）",
                }
            ),
            400,
        )
    resp = strategy_start(bot_id)
    _db.strategy_event_insert(bot_id, "start", "manual", None)
    return jsonify(resp)


@app.route("/api/strategy/stop", methods=["POST", "GET"])
@require_auth
def api_strategy_stop():
    denied = _require_trader_or_admin()
    if denied:
        return denied
    bot_id = (
        request.args.get("bot_id")
        or (request.get_json(silent=True) or {}).get("bot_id")
    ) or ""
    if not _bot_is_controllable(bot_id):
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "缺少或无效的 bot_id（simpleserver-* 或 Account_List 中已配置 script_file）",
                }
            ),
            400,
        )
    resp = strategy_stop(bot_id)
    _db.strategy_event_insert(bot_id, "stop", "manual", None)
    return jsonify(resp)


@app.route("/api/strategy/restart", methods=["POST", "GET"])
@require_auth
def api_strategy_restart():
    denied = _require_trader_or_admin()
    if denied:
        return denied
    bot_id = (
        request.args.get("bot_id")
        or (request.get_json(silent=True) or {}).get("bot_id")
    ) or ""
    if not _bot_is_controllable(bot_id):
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "缺少或无效的 bot_id（simpleserver-* 或 Account_List 中已配置 script_file）",
                }
            ),
            400,
        )
    resp = strategy_restart(bot_id)
    _db.strategy_event_insert(bot_id, "restart", "manual", None)
    return jsonify(resp)


# ---------- API：日志查询（需登录，便于排查） ----------
@app.route("/api/logs", methods=["GET"])
@require_auth
def api_logs():
    """查询最近日志，query: limit=100, level=INFO|WARN|ERROR, source=login|api。"""
    if _is_customer():
        return jsonify({"success": False, "message": "客户无权查看系统日志"}), 403
    limit = min(int(request.args.get("limit", 100)), 500)
    level = request.args.get("level") or None
    source = request.args.get("source") or None
    rows = _db.log_query(limit=limit, level=level, source=source)
    return jsonify({"success": True, "logs": rows})


# ---------- API：Account_List.json（仅管理员） ----------
@app.route("/api/admin/accounts", methods=["GET"])
@require_auth
def api_admin_accounts_list():
    denied = _require_admin()
    if denied:
        return denied
    return jsonify(
        {"success": True, "accounts": _account_list_store.list_accounts()}
    )


@app.route("/api/admin/accounts", methods=["POST"])
@require_auth
def api_admin_accounts_create():
    denied = _require_admin()
    if denied:
        return denied
    data = request.get_json(silent=True) or {}
    aid = str(data.get("account_id") or "").strip()
    if not aid:
        return jsonify({"success": False, "message": "缺少 account_id"}), 400
    if _account_list_store.get_account(aid):
        return jsonify(
            {"success": False, "message": "account_id 已存在"}
        ), 409
    try:
        row = _account_list_store.upsert_account(data)
    except ValueError as e:
        return jsonify({"success": False, "message": str(e)}), 400
    err = _sync_account_list_after_list_json_write()
    if err:
        return err
    return jsonify({"success": True, "account": row})


@app.route("/api/admin/accounts/<account_id>", methods=["GET"])
@require_auth
def api_admin_accounts_one(account_id):
    denied = _require_admin()
    if denied:
        return denied
    row = _account_list_store.get_account(account_id)
    if not row:
        return jsonify({"success": False, "message": "未找到"}), 404
    return jsonify({"success": True, "account": row})


@app.route("/api/admin/accounts/<account_id>", methods=["PUT", "PATCH"])
@require_auth
def api_admin_accounts_update(account_id):
    denied = _require_admin()
    if denied:
        return denied
    aid = (account_id or "").strip()
    existing = _account_list_store.get_account(aid)
    if not existing:
        return jsonify({"success": False, "message": "未找到"}), 404
    patch = request.get_json(silent=True) or {}
    merged = {**existing, **patch}
    merged["account_id"] = aid
    try:
        row = _account_list_store.upsert_account(merged)
    except ValueError as e:
        return jsonify({"success": False, "message": str(e)}), 400
    err = _sync_account_list_after_list_json_write()
    if err:
        return err
    return jsonify({"success": True, "account": row})


@app.route("/api/admin/accounts/<account_id>", methods=["DELETE"])
@require_auth
def api_admin_accounts_delete(account_id):
    denied = _require_admin()
    if denied:
        return denied
    aid = (account_id or "").strip()
    if not _account_list_store.delete_account(aid):
        return jsonify({"success": False, "message": "未找到"}), 404
    err = _sync_account_list_after_list_json_write()
    if err:
        return err
    return jsonify({"success": True, "message": "已删除"})


@app.route("/api/admin/accounts/<account_id>/test-connection", methods=["POST"])
@require_auth
def api_admin_accounts_test(account_id):
    denied = _require_admin()
    if denied:
        return denied
    return _okx_account_test_http_response(account_id)


@app.route("/api/me/customer-accounts", methods=["GET"])
@require_auth
def api_me_customer_accounts():
    if not _is_customer():
        return jsonify({"success": False, "message": "仅客户可使用此接口"}), 403
    linked = _db.user_get_linked_account_ids(g.current_username)
    out: list[dict] = []
    for aid in linked:
        aid = (aid or "").strip()
        if not aid:
            continue
        row = _account_list_store.get_account(aid)
        if not row:
            out.append(
                {
                    "account_id": aid,
                    "missing_in_account_list": True,
                    "key_file_exists": False,
                }
            )
            continue
        basic = _account_mgr.account_basic_dict(row)
        wp = _account_mgr.resolve_okx_key_write_path(aid)
        basic["key_file_exists"] = bool(wp and wp.is_file())
        basic["missing_in_account_list"] = False
        out.append(basic)
    return jsonify({"success": True, "accounts": out})


@app.route("/api/me/customer-accounts/<account_id>/okx-json", methods=["PUT"])
@require_auth
def api_me_customer_okx_json(account_id):
    if not _is_customer():
        return jsonify({"success": False, "message": "仅客户可上传密钥"}), 403
    aid = (account_id or "").strip()
    allowed = {x.strip() for x in _db.user_get_linked_account_ids(g.current_username) if x}
    if aid not in allowed:
        return jsonify({"success": False, "message": "未绑定该账户，请联系管理员"}), 403
    data = request.get_json(silent=True)
    body, verr = _validate_customer_okx_json_body(data)
    if verr:
        return jsonify({"success": False, "message": verr}), 400
    if not _account_list_store.get_account(aid):
        return jsonify({"success": False, "message": "服务端无此账户配置，请联系管理员维护 Account_List"}), 404
    path = _account_mgr.resolve_okx_key_write_path(aid)
    if path is None:
        return jsonify({"success": False, "message": "无法解析密钥保存路径"}), 400
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(body, f, ensure_ascii=False, indent=2)
        f.write("\n")
    _account_mgr.invalidate_okx_ccxt_exchange_cache(path)
    return jsonify(
        {"success": True, "message": "已保存", "account_key_file": path.name}
    )


@app.route("/api/me/customer-accounts/<account_id>/test-connection", methods=["POST"])
@require_auth
def api_me_customer_accounts_test(account_id):
    if not _is_customer():
        return jsonify({"success": False, "message": "仅客户可测连"}), 403
    aid = (account_id or "").strip()
    allowed = {x.strip() for x in _db.user_get_linked_account_ids(g.current_username) if x}
    if aid not in allowed:
        return jsonify({"success": False, "message": "未绑定该账户"}), 403
    return _okx_account_test_http_response(aid)


# ---------- API：OKX 账户信息（脱敏） ----------
@app.route("/api/okx/info", methods=["GET"])
def api_okx_info():
    info = _okx.okx_info_safe()
    if info is None:
        return jsonify({"ok": False, "error": "OKX 配置不存在或不可读"}), 404
    return jsonify({"ok": True, "info": info})


# 启动 5 分钟定时器：AccountMgr 写入 account_balance_snapshots、account_open_positions_snapshots、account_positions_history，并兼容 tradingbots 盈利快照
# 夜间：PEPE（可配置）1m 标记价格 K 线写入 flutter_app/web/kline，并由 /kline/ 提供静态 JSON
# 多 worker（gunicorn 等）下用文件锁保证仅一个进程跑后台任务，避免重复同步与日志交错
if _BACKGROUND_SCHEDULERS_ENABLED:
    _bg_leader_ok = _try_acquire_background_scheduler_leader_lock()
    _BACKGROUND_SCHEDULER_IS_LEADER = _bg_leader_ok
    if _bg_leader_ok:
        app.logger.info(
            "后台定时任务 leader（API 服务）：pid=%s ppid=%s（账户同步/月初/K 线）；"
            "排查多实例: pgrep -af 'server/main.py'；gunicorn 查 -w；FLASK_DEBUG=1 时注意重载子进程",
            os.getpid(),
            os.getppid(),
        )
        _start_account_snapshot_timer()
        _start_account_month_open_timer()
        threading.Thread(
            target=_bootstrap_account_month_open_if_needed_on_startup,
            name="account_month_open_bootstrap",
            daemon=True,
        ).start()
        _kline_web_sync.start_kline_nightly_scheduler(app.logger, PROJECT_ROOT)
    else:
        app.logger.info(
            "后台定时任务由其他进程持有锁，本 worker 跳过：pid=%s ppid=%s",
            os.getpid(),
            os.getppid(),
        )

# App 进程启停写入 strategy_events（bot_id="app"），便于审计
_APP_EVENT_BOT_ID = "app"
_app_stop_written = False


def _app_on_stop():
    """进程退出时写一条 app stop 事件（SIGTERM/SIGINT/atexit 只写一次）。"""
    global _app_stop_written
    if _app_stop_written:
        return
    _app_stop_written = True
    try:
        _db.strategy_event_insert(_APP_EVENT_BOT_ID, "stop", "auto", None)
    except Exception:
        pass


def _app_on_stop_signal(*_args):
    """信号处理：写库后退出。"""
    _app_on_stop()
    sys.exit(0)


@app.route("/kline/<path:kline_rel>")
def serve_kline_json(kline_rel: str):
    """Flutter `web/kline` 下 JSON（OKX 1m 标记价格 K 线同步产物），供前端或 QTrader-web 类客户端拉取。"""
    if ".." in kline_rel or kline_rel.startswith(("/", "\\")):
        abort(404)
    if not kline_rel.lower().endswith(".json"):
        abort(404)
    base = _kline_web_sync.kline_output_dir(PROJECT_ROOT).resolve()
    full = (base / kline_rel).resolve()
    try:
        full.relative_to(base)
    except ValueError:
        abort(404)
    if not full.is_file():
        abort(404)
    return send_file(full, mimetype="application/json", max_age=120)


if __name__ == "__main__":
    try:
        _db.strategy_event_insert(_APP_EVENT_BOT_ID, "start", "auto", None)
    except Exception:
        pass
    atexit.register(_app_on_stop)
    signal.signal(signal.SIGTERM, _app_on_stop_signal)
    signal.signal(signal.SIGINT, _app_on_stop_signal)
    # 端口由环境变量 PORT 指定（默认 9001，与 Flutter API 预设一致）
    port = int(os.environ.get("PORT", 9001))
    app.run(host="0.0.0.0", port=port, debug=os.environ.get("FLASK_DEBUG", "0") == "1")
