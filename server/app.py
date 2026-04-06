# -*- coding: utf-8 -*-
"""
MobileApp API + Flutter Web 静态站点（部署于 AWS）
- API（JSON）：App / Flutter Web 共用，路径 /api/*
- Web UI：由 flutter build web 产物提供（与移动端同一套 Dart），未构建时返回简短说明页
- 静态资源：GET /download/apk/<name>.apk、GET /res/bg

App 所需 API（与 QtraderApi.kt 一致）：
  POST /api/login                 登录，Body: {username, password}，返回 {success, token}
  GET  /api/account-profit        账户盈亏（需 Bearer token）
  GET  /api/tradingbots           交易账户列表（需 Bearer token）
  POST /api/tradingbots/{id}/start|stop|restart（需 Bearer token，仅 simpleserver-lhg、simpleserver-hztech）
  GET  /api/tradingbots/{id}/tradingbot-events  账户启停事件（需 Bearer token）
  GET  /api/logs                  日志查询（需 Bearer token，?limit=100&level=&source=）
  GET  /api/users                 用户列表（需 Bearer token，用户管理以 DB 为准）
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
from datetime import datetime, timezone
from pathlib import Path
from functools import wraps
import jwt
from flask import Flask, abort, jsonify, request, send_file, send_from_directory, g

import db as _db
from exchange import okx as _okx

from tradingbot_ctrl import (
    start as strategy_start,
    stop as strategy_stop,
    restart as strategy_restart,
    season_start as strategy_season_start,
    season_stop as strategy_season_stop,
    status as strategy_status,
    BOT_SCRIPTS as _BOT_SCRIPTS,
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


# CORS：允许 Flutter Web / 浏览器跨域请求 API，避免 "Failed to fetch"
@app.after_request
def _add_cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Methods"] = (
        "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    )
    resp.headers["Access-Control-Allow-Headers"] = (
        "Content-Type, Authorization, Accept, Access-Control-Request-Private-Network"
    )
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
CONFIG_DIR = SERVER_DIR / "Accounts"
# APK 所在目录（可放多个版本），默认项目根下 apk/，对应 AWS 上 hztechapp/apk/
APK_DIR = Path(os.environ.get("APK_DIR", str(PROJECT_ROOT / "apk")))
# 资源目录：res 已移至 server/res（密钥、背景图等）
RES_DIR = SERVER_DIR / "res"
# OKX 配置路径（API 脱敏、定时拉取账户余额）：由 okx 模块解析默认路径
OKX_CONFIG_PATH = _okx.get_default_config_path(CONFIG_DIR)
# Flutter Web 构建目录（flutter build web），可用环境变量 FLUTTER_WEB_ROOT 覆盖
FLUTTER_WEB_DIR = Path(
    os.environ.get(
        "FLUTTER_WEB_ROOT", str(PROJECT_ROOT / "flutter_app" / "build" / "web")
    )
)
# JWT：优先从 DB config 读，否则环境变量
_db.init_db()


def _get_jwt_secret() -> str:
    return _db.config_get("jwt_secret") or os.environ.get(
        "JWT_SECRET", "hztech-mobileapp-secret-change-in-production"
    )


def _get_jwt_exp_days() -> int:
    v = _db.config_get("jwt_exp_days")
    if v is not None:
        try:
            return int(v)
        except (TypeError, ValueError):
            pass
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
                "app.py:require_auth",
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
        return f(*args, **kwargs)

    return wrapped


def _load_tradingbots_config() -> list[dict]:
    """从 server/Accounts/tradingbots.json 读取交易账户列表，不存在则返回默认两 bot（lhg、hztech）。"""
    path = CONFIG_DIR / "tradingbots.json"
    if path.exists():
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list):
                return data
        except Exception:
            pass
    return [
        {
            "tradingbot_id": "simpleserver-lhg",
            "tradingbot_name": "LHG Bot",
            "exchange_account": "OKX",
            "symbol": "BTC-USDT-SWAP",
            "strategy_name": "simpleserver-lhg",
        },
        {
            "tradingbot_id": "simpleserver-hztech",
            "tradingbot_name": "Hztech Bot",
            "exchange_account": "OKX",
            "symbol": "BTC-USDT-SWAP",
            "strategy_name": "simpleserver-hztech",
        },
    ]


def _bot_okx_config_path(bot_id: str) -> Path | None:
    """仅从 Accounts/tradingbots.json 解析该 bot 的 OKX 配置文件路径，不落库、不缓存、不回退到全局。
    一切以 Accounts 目录为准：若 account_api_file 未配置或文件不在 CONFIG_DIR 下则返回 None。"""
    bots = _load_tradingbots_config()
    for b in bots:
        if (b.get("tradingbot_id") or "").strip() != bot_id:
            continue
        api_file = (b.get("account_api_file") or "").strip()
        if not api_file:
            return None
        path = CONFIG_DIR / api_file
        if not path.exists():
            return None
        return path
    return None


def _live_equity_cash_for_bot(bot_id: str) -> tuple[float, float]:
    path = _bot_okx_config_path(bot_id)
    if not path or not path.is_file():
        return 0.0, 0.0
    live = _okx.okx_fetch_balance(config_path=path)
    if not live:
        return 0.0, 0.0
    eq = float(live.get("equity_usdt") or live.get("total_eq") or 0.0)
    cash = float(live.get("cash_balance") or live.get("avail_eq") or 0.0)
    return eq, cash


def _job_fetch_account_and_save_snapshots() -> None:
    """定时任务：按 bot 的 account_api_file 分别拉取账号信息并写入 bot_profit_snapshots（每 10 分钟）。仅用 Accounts 下配置，不回退全局。"""
    bots = _load_tradingbots_config()
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    for b in bots:
        bot_id = (b.get("tradingbot_id") or "").strip()
        if not bot_id:
            continue
        config_path = _bot_okx_config_path(bot_id)
        if not config_path:
            app.logger.debug(
                "account_snapshot_skip: bot_id=%s 未在 Accounts 下配置 account_api_file 或文件不存在",
                bot_id,
            )
            continue
        try:
            balance = _okx.okx_fetch_balance(config_path=config_path)
            if balance is None:
                app.logger.info(
                    "account_snapshot_skip: bot_id=%s config=%s (同一台机若 testapi 正常而此处失败，可对照 Accounts 下同一配置文件)",
                    bot_id,
                    config_path.name,
                )
                _db.log_insert(
                    "WARN",
                    "account_snapshot_skip",
                    source="timer",
                    extra={
                        "bot_id": bot_id,
                        "config": config_path.name,
                        "reason": "balance_fetch_failed",
                    },
                )
                continue
            total_eq = balance.get("total_eq") or 0.0
            prev = _db.bot_profit_latest_by_bot(bot_id)
            initial = float(prev["initial_balance"]) if prev else total_eq
            if prev is None and total_eq > 0:
                initial = total_eq
            profit_amount = total_eq - initial
            profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
            _db.bot_profit_insert(
                bot_id=bot_id,
                snapshot_at=ts,
                initial_balance=initial,
                current_balance=total_eq,
                equity_usdt=total_eq,
                profit_amount=profit_amount,
                profit_percent=profit_percent,
            )
        except Exception as e:
            _db.log_insert(
                "WARN",
                "account_snapshot_failed",
                source="timer",
                extra={"bot_id": bot_id, "error": str(e)},
            )


def _start_account_snapshot_timer() -> None:
    """后台线程：每 10 分钟执行一次账号快照；启动后 30 秒执行第一次。"""

    def _loop() -> None:
        time.sleep(30)
        while True:
            try:
                _job_fetch_account_and_save_snapshots()
            except Exception as e:
                _db.log_insert(
                    "WARN",
                    "account_snapshot_timer_error",
                    source="timer",
                    extra={"error": str(e)},
                )
            time.sleep(60 * 10)

    t = threading.Thread(target=_loop, daemon=True)
    t.start()


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
    return jsonify({"success": True, "token": token, "message": "ok"})


@app.route("/api/users", methods=["GET"])
@require_auth
def api_users():
    """用户列表（仅 id、username、created_at），用户管理以 DB 为准。"""
    rows = _db.user_list()
    return jsonify({"success": True, "users": rows})


def _collect_accounts_profit() -> list[dict]:
    """与 /api/account-profit 返回的 accounts 数组一致。"""
    bots = _load_tradingbots_config()
    accounts = []
    for b in bots:
        bot_id = (b.get("tradingbot_id") or "").strip()
        if not bot_id:
            continue
        config_path = _bot_okx_config_path(bot_id)
        live = _okx.okx_fetch_balance(config_path=config_path) if config_path else None
        snap = _db.bot_profit_latest_by_bot(bot_id)
        exchange_account = b.get("exchange_account") or bot_id
        if live:
            total_eq = live.get("total_eq") or 0.0
            avail_eq = live.get("avail_eq") or total_eq
            upl = live.get("upl") or 0.0
            initial = float(snap["initial_balance"]) if snap else total_eq
            profit_amount = total_eq - initial
            profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
            accounts.append(
                {
                    "bot_id": bot_id,
                    "exchange_account": exchange_account,
                    "initial_balance": initial,
                    "current_balance": total_eq,
                    "profit_amount": profit_amount,
                    "profit_percent": profit_percent,
                    "floating_profit": upl,
                    "equity_usdt": total_eq,
                    "balance_usdt": avail_eq,
                    "snapshot_time": snap["snapshot_at"] if snap else None,
                }
            )
        elif snap:
            accounts.append(
                {
                    "bot_id": bot_id,
                    "exchange_account": exchange_account,
                    "initial_balance": snap["initial_balance"],
                    "current_balance": snap["current_balance"],
                    "profit_amount": snap["profit_amount"],
                    "profit_percent": snap["profit_percent"],
                    "floating_profit": snap["profit_amount"],
                    "equity_usdt": snap["equity_usdt"],
                    "balance_usdt": snap["current_balance"],
                    "snapshot_time": snap["snapshot_at"],
                }
            )
        else:
            accounts.append(
                {
                    "bot_id": bot_id,
                    "exchange_account": exchange_account,
                    "initial_balance": 0,
                    "current_balance": 0,
                    "profit_amount": 0,
                    "profit_percent": 0,
                    "floating_profit": 0,
                    "equity_usdt": 0,
                    "balance_usdt": 0,
                    "snapshot_time": None,
                }
            )
    return accounts


# ---------- API：App 所需（与 QtraderApi 一致，需登录） ----------
@app.route("/api/account-profit", methods=["GET"])
@require_auth
def api_account_profit():
    """账户盈亏：按 bot 的 account_api_file 拉 OKX 实时权益/余额/浮亏，快照提供月初与曲线数据。"""
    accounts = _collect_accounts_profit()
    return jsonify(
        {
            "success": True,
            "accounts": accounts,
            "total_count": len(accounts),
        }
    )


# 支持启停的 bot_id 集合（与 bot_ctrl.BOT_SCRIPTS 一致，仅此两个 bot）
CONTROLLABLE_BOT_IDS = set(_BOT_SCRIPTS.keys())


def _collect_tradingbots_list() -> list[dict]:
    """与 /api/tradingbots 返回的 bots 数组一致。"""
    st = strategy_status()
    bots_status = st.get("bots") or {}
    bots_config = _load_tradingbots_config()
    bots = []
    for b in bots_config:
        bot_id = (b.get("tradingbot_id") or "").strip()
        if not bot_id:
            continue
        bot_st = bots_status.get(bot_id) or {}
        is_running = bot_st.get("running", False)
        can_control = bot_id in CONTROLLABLE_BOT_IDS
        bots.append(
            {
                "tradingbot_id": bot_id,
                "tradingbot_name": b.get("tradingbot_name") or bot_id,
                "exchange_account": b.get("exchange_account"),
                "symbol": b.get("symbol"),
                "strategy_name": b.get("strategy_name"),
                "status": "running" if is_running else "stopped",
                "is_running": is_running,
                "can_control": can_control,
                "enabled": bool(b.get("enabled")),
                "sandbox": False,
            }
        )
    return bots


# 交易账户列表：从 server/Accounts/tradingbots.json 读取，运行状态按 bot 分别查询
@app.route("/api/tradingbots", methods=["GET"])
@require_auth
def api_tradingbots():
    bots = _collect_tradingbots_list()
    # #region agent log
    _debug_log(
        "app.py:api_tradingbots",
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
    if bot_id not in CONTROLLABLE_BOT_IDS:
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
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/tradingbots/<bot_id>/stop", methods=["POST"])
@require_auth
def api_bot_stop(bot_id):
    if bot_id not in CONTROLLABLE_BOT_IDS:
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
        final_eq, final_cash = _live_equity_cash_for_bot(bot_id)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        _db.bot_season_update_on_stop(bot_id, ts, final_eq, final_cash)
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/tradingbots/<bot_id>/restart", methods=["POST"])
@require_auth
def api_bot_restart(bot_id):
    if bot_id not in CONTROLLABLE_BOT_IDS:
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
    if bot_id not in CONTROLLABLE_BOT_IDS:
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    resp = strategy_season_start(bot_id)
    _db.log_insert(
        "INFO",
        "season_start_api",
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
        _db.bot_season_roll_forward(bot_id, ts, eq, cash)
        _db.strategy_event_insert(
            bot_id,
            "season_start",
            "manual",
            getattr(g, "current_username", None),
        )
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/tradingbots/<bot_id>/season-stop", methods=["POST"])
@require_auth
def api_bot_season_stop(bot_id):
    if bot_id not in CONTROLLABLE_BOT_IDS:
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
        _db.bot_season_update_on_stop(bot_id, ts, eq, cash)
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
    """机器人盈利历史（用于收益曲线图），按 snapshot_at 升序。"""
    limit = min(int(request.args.get("limit", 500)), 1000)
    rows = _db.bot_profit_query_by_bot(bot_id, limit=limit)
    return jsonify({"success": True, "bot_id": bot_id, "snapshots": rows})


@app.route("/api/okx/positions", methods=["GET"])
@require_auth
def api_okx_positions():
    """当前持仓（OKX 实时，全局配置），含数量/持仓成本/当前价 last_px/动态盈亏 upl。"""
    positions, err = _okx.okx_fetch_positions(config_path=None)
    return jsonify({"success": True, "positions": positions, "positions_error": err})


@app.route("/api/tradingbots/<bot_id>/positions", methods=["GET"])
@require_auth
def api_bot_positions(bot_id):
    """指定 bot 的当前持仓（按 account_api_file 拉 OKX），含数量、持仓成本、当前价位、动态盈亏。"""
    if _DEBUG_POSITIONS:
        app.logger.info("[持仓-API] 收到请求 bot_id=%s", bot_id)
    # #region agent log
    _debug_log(
        "app.py:api_bot_positions:entry",
        "positions request",
        {"bot_id": bot_id},
        "H1",
    )
    # #endregion
    config_path = _bot_okx_config_path(bot_id)
    # #region agent log
    _debug_log(
        "app.py:api_bot_positions:config",
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
                "positions_error": "bot 未在 Accounts/tradingbots.json 配置 account_api_file 或该文件不在 Accounts 目录下",
            }
        )
    positions, positions_error = _okx.okx_fetch_positions(config_path=config_path)
    # #region agent log
    _debug_log(
        "app.py:api_bot_positions",
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


@app.route("/api/tradingbots/<bot_id>/seasons", methods=["GET"])
@require_auth
def api_tradingbot_seasons(bot_id):
    """指定机器人的赛季信息：启停时间、初期金额、盈利、盈利率。"""
    limit = min(int(request.args.get("limit", 50)), 100)
    rows = _db.bot_season_list_by_bot(bot_id, limit=limit)
    return jsonify({"success": True, "bot_id": bot_id, "seasons": rows})


@app.route("/api/tradingbots/<bot_id>/tradingbot-events", methods=["GET"])
@require_auth
def api_bot_tradingbot_events(bot_id):
    """机器人启停事件记录（手动/自动、时间、操作人）。"""
    limit = min(int(request.args.get("limit", 50)), 200)
    rows = _db.strategy_event_query(bot_id=bot_id, limit=limit)
    return jsonify({"success": True, "bot_id": bot_id, "events": rows})


# ---------- API：策略（Web 管控用，需 query bot_id=simpleserver-lhg|simpleserver-hztech） ----------
@app.route("/api/strategy/status", methods=["GET"])
def api_strategy_status():
    return jsonify(strategy_status())


@app.route("/api/strategy/start", methods=["POST", "GET"])
def api_strategy_start():
    bot_id = (
        request.args.get("bot_id")
        or (request.get_json(silent=True) or {}).get("bot_id")
    ) or ""
    if bot_id not in CONTROLLABLE_BOT_IDS:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "缺少或无效的 bot_id，需为 simpleserver-lhg 或 simpleserver-hztech",
                }
            ),
            400,
        )
    resp = strategy_start(bot_id)
    _db.strategy_event_insert(bot_id, "start", "manual", None)
    return jsonify(resp)


@app.route("/api/strategy/stop", methods=["POST", "GET"])
def api_strategy_stop():
    bot_id = (
        request.args.get("bot_id")
        or (request.get_json(silent=True) or {}).get("bot_id")
    ) or ""
    if bot_id not in CONTROLLABLE_BOT_IDS:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "缺少或无效的 bot_id，需为 simpleserver-lhg 或 simpleserver-hztech",
                }
            ),
            400,
        )
    resp = strategy_stop(bot_id)
    _db.strategy_event_insert(bot_id, "stop", "manual", None)
    return jsonify(resp)


@app.route("/api/strategy/restart", methods=["POST", "GET"])
def api_strategy_restart():
    bot_id = (
        request.args.get("bot_id")
        or (request.get_json(silent=True) or {}).get("bot_id")
    ) or ""
    if bot_id not in CONTROLLABLE_BOT_IDS:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "缺少或无效的 bot_id，需为 simpleserver-lhg 或 simpleserver-hztech",
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
    limit = min(int(request.args.get("limit", 100)), 500)
    level = request.args.get("level") or None
    source = request.args.get("source") or None
    rows = _db.log_query(limit=limit, level=level, source=source)
    return jsonify({"success": True, "logs": rows})


# ---------- API：OKX 账号信息（脱敏） ----------
@app.route("/api/okx/info", methods=["GET"])
def api_okx_info():
    info = _okx.okx_info_safe()
    if info is None:
        return jsonify({"ok": False, "error": "OKX 配置不存在或不可读"}), 404
    return jsonify({"ok": True, "info": info})


# 启动 10 分钟定时器：拉取账号信息并写入盈利快照
_start_account_snapshot_timer()

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


def _flutter_web_safe_path(root: Path, rel: str) -> Path | None:
    """将 URL 路径解析为 root 下的文件路径，防止跳出目录。"""
    if ".." in rel or rel.startswith("/"):
        return None
    rel = rel.strip("/")
    if not rel:
        return root / "index.html"
    full = (root / rel).resolve()
    try:
        full.relative_to(root.resolve())
    except ValueError:
        return None
    return full


@app.route("/", defaults={"spa_path": ""})
@app.route("/<path:spa_path>")
def serve_flutter_web(spa_path: str):
    """托管 Flutter Web（flutter build web）；未知路径回退 index.html 以支持前端路由。"""
    if spa_path == "api" or spa_path.startswith("api/"):
        return jsonify({"error": "not_found", "path": "/" + spa_path}), 404
    root = FLUTTER_WEB_DIR.resolve()
    index_html = root / "index.html"
    if not index_html.is_file():
        body = (
            "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"UTF-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>禾正量化</title></head>"
            "<body style=\"font-family:system-ui,sans-serif;padding:2rem;max-width:560px;line-height:1.5;\">"
            "<h1>Flutter Web 未构建</h1>"
            "<p>REST API 仍可通过 <code>/api/</code> 访问（与移动端共用）。</p>"
            "<p>构建 Web 端：</p><pre style=\"background:#f4f4f5;padding:1rem;border-radius:8px;\">"
            "cd flutter_app && flutter build web</pre>"
            "<p>或通过环境变量 <code>FLUTTER_WEB_ROOT</code> 指定已构建目录。</p>"
            "</body></html>"
        )
        return body, 200, {"Content-Type": "text/html; charset=utf-8"}
    rel = spa_path.strip("/")
    if not rel:
        return send_from_directory(str(root), "index.html")
    target = _flutter_web_safe_path(root, rel)
    if target is None:
        abort(404)
    if target.is_file():
        return send_from_directory(str(root), rel)
    return send_from_directory(str(root), "index.html")


if __name__ == "__main__":
    try:
        _db.strategy_event_insert(_APP_EVENT_BOT_ID, "start", "auto", None)
    except Exception:
        pass
    atexit.register(_app_on_stop)
    signal.signal(signal.SIGTERM, _app_on_stop_signal)
    signal.signal(signal.SIGINT, _app_on_stop_signal)
    # 单进程同时提供 /api/* 与 Flutter Web 静态资源；端口由环境变量 PORT 指定（默认 8080）
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=os.environ.get("FLASK_DEBUG", "0") == "1")
