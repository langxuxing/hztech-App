# -*- coding: utf-8 -*-
"""
MobileApp API 服务（部署于 AWS 等）
- API（JSON）：App / Flutter Web 共用，路径 /api/*
- Flutter Web 静态资源由 flutterapp/web_static/serve_web_static.py（或兼容入口 baasapi/serve_web_static.py）或 CDN 托管
- 文件端点：GET /download/apk/<name>.apk（客户端统一短链）、GET /api/download/apk/<name>.apk（nginx 仅反代 /api/ 时兼容）、GET /res/bg；K 线 JSON：GET /kline/<file>.json
- 日志：默认 werkzeug 静默；HZTECH_API_ACCESS_LOG=1 打印关键请求（跳过 /api/health、/kline/）；LOG_LEVEL=DEBUG 打印全量请求摘要；本地 ./baasapi/run_local.sh 默认 LOG_LEVEL=DEBUG、FLASK_DEBUG=1、HZTECH_API_REQUEST_STATS=1

App 所需 API（与 QtraderApi.kt 一致）：
  POST /api/login                 登录，Body: {username, password}，返回 {success, token}
  GET  /api/account-profit        账户盈亏（需 Bearer token）
  GET  /api/accounts              交易账户列表（需 Bearer token；原 /api/tradingbots 列表）
  POST /api/tradingbots/{id}/start|stop|restart|season-start|season-stop  策略机器人管控（需 Bearer token；start 支持 ?force=true 先停再起；赛季脚本侧为 `--season start|stop`；status 子命令供运行态 JSON；season-start 先写 account_season 再按需启动策略进程，再执行赛季脚本；season-stop 仅结束赛季记录，不强制 stop 进程；stop 会写当前未结赛季止期及期末权益/现金）
  GET  /api/tradingbots/{id}/seasons/{season_id}/positions-summary  赛季区间内历史平仓笔数与净盈亏（Account_List；策略/赛季维度）
  GET  /api/accounts/{account_id}/pending-orders | /ticker  当前委托、行情（不入库；路径参数为 Account_List 的 account_id）
  POST /api/accounts/{account_id}/trade/execute  手工交易（仅交易员/管理员）：Body JSON op=open_long|open_short|close_long|close_short|close_all|balance_long_short，可选 sz、inst_id、auto_tp、ord_type、limit_px
  GET  /api/accounts/{account_id}/profit-history  收益曲线快照（?limit=&since=，默认近 45 天、最多 15000 条）
  GET  /api/accounts/{account_id}/strategy-daily-efficiency  策略效能：现金/权益收益率%、能效、ATR14 与阈值（?inst_id=&days=）
  GET  /api/accounts/{account_id}/daily-realized-pnl | /positions | /seasons  日已实现盈亏、OKX 实时持仓、赛季列表
  GET  /kline/<file>.json  PEPE 等 1m 标记价格 K 线 JSON（写入 flutterapp/web/kline；夜间定时补历史）
  GET  /api/accounts/{account_id}/tradingbot-events  账户启停事件（需 Bearer token）
  GET  /api/logs                  日志查询（需 Bearer token，?limit=100&level=&source=）
  GET  /api/users                 用户列表（仅管理员，含 role、linked_account_ids、full_name、phone）
  POST /api/users                 新建用户（仅管理员）Body: {username, password, role?, linked_account_ids?, full_name?, phone?}
  DELETE /api/users/<id>          删除用户（仅管理员，不可删自己）
  PATCH /api/users/<id>           更新角色/客户绑定/全名/手机（仅管理员）
  POST /api/strategy-analyst/auto-net-test  自动收网测试桩（管理员/策略分析师；交易员与客户不可用）
  GET  /api/me                    当前用户 role、linked_account_ids
  GET  /api/health                服务存活（无需登录，供负载均衡探测）
  GET  /api/app-version           移动端版本策略（无需登录；HZTECH_APP_* 环境变量）
  GET  /api/status                同步状态与周期说明（需登录）；含 http_request_stats（本进程 HTTP 计数，见环境变量 HZTECH_API_REQUEST_STATS）
  GET  /api/accounts/{account_id}/position-history  历史仓位分页（入库数据，需登录）
  POST /api/accounts/{account_id}/position-history/sync  手动拉取该账户 OKX 历史仓位（仅管理员）
  POST /api/accounts/{account_id}/balance-snapshot/sync  立即拉取 OKX 余额写入 account_balance_snapshots（仅管理员；须为 Account_List 账户）
  GET  /api/accounts/{account_id}/open-positions-snapshots  已入库的当前持仓聚合快照（含多/空预估强平价；按时间倒序；需登录）
  POST /api/accounts/{account_id}/open-positions-snapshot/sync  立即拉取 OKX 当前持仓写入 account_open_positions_snapshots（仅管理员）
  POST /api/admin/balance-snapshots/sync  全量余额快照同步（与定时任务相同；仅管理员）
  POST /api/admin/balance-snapshots/recompute-profit  按 initial_capital 重算全表 equity_profit_*（权益）与 balance_profit_*（资产余额）（仅管理员）
  POST /api/admin/balance-snapshots/backfill-bills  按 OKX bills-archive 补全缺日 account_balance_snapshots（仅管理员；不由账户同步定时器执行；亦可 ``baasapi/pg_data_fill.py`` / ``aws-ops/code/balance_snapshots_bills_backfill.sh``）
  GET|POST|PUT|DELETE /api/admin/accounts  以 account_list 为准；写库后同步落盘 Account_List.json（仅管理员）
  POST /api/admin/accounts/{id}/test-connection  测连 OKX + 检查 SWAP/双向持仓/50x 杠杆（仅管理员）；Body 可选 {"auto_configure": true} 在测连成功后调用 OKX 设双向持仓/全仓/多空杠杆后复测
  GET  /api/me/customer-accounts  客户已绑定账户列表与密钥文件是否存在（仅客户）
  PUT  /api/me/customer-accounts/{id}/okx-json  客户上传 OKX 密钥 JSON（须已绑定该 account_id）
  POST /api/me/customer-accounts/{id}/test-connection  客户测连（同管理员）；Body 可选 {"auto_configure": true}
  GET  /api/okx/info
"""
from __future__ import annotations

import atexit
import hashlib
import json
import logging
import os
import random
import signal
import sys
import time
import threading

try:
    import fcntl
except ImportError:
    fcntl = None  # Windows：无 flock，按单进程处理

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from pathlib import Path
from functools import wraps
import jwt
from flask import Flask, abort, jsonify, request, send_file, g

import db as _db
import account_list_store as _account_list_store
import strategy_efficiency as _strategy_efficiency
import account_manual_trade as _account_manual_trade
import kline_web_sync as _kline_web_sync
import pg_data_fill as _pg_data_fill
from accounts import AccountMgr as _account_mgr
from accounts.account_key_util import account_row_is_enabled as _account_row_is_enabled
from exchange import okx as _okx
from hztech_log_format import hztech_console_formatter
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

# #region agent log（默认关闭：避免热路径同步写盘导致高 CPU；排查时设 HZTECH_AGENT_DEBUG_LOG=1）
_AGENT_DEBUG_LOG_ENABLED = os.environ.get("HZTECH_AGENT_DEBUG_LOG", "").strip().lower() in (
    "1",
    "true",
    "yes",
)


def _debug_log(location: str, message: str, data: dict, hypothesis_id: str) -> None:
    if not _AGENT_DEBUG_LOG_ENABLED:
        return
    raw_path = (os.environ.get("HZTECH_AGENT_DEBUG_LOG_PATH") or "").strip()
    if raw_path:
        log_path = Path(raw_path).expanduser()
    else:
        log_path = (
            Path(__file__).resolve().parent.parent
            / ".temp-cursor"
            / "agent-debug.log"
        )
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(
                json.dumps(
                    {
                        "sessionId": os.environ.get(
                            "HZTECH_AGENT_DEBUG_SESSION_ID", "default"
                        ),
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

# 日志行首标签，便于与 FlutterApp 静态进程区分；可用 HZTECH_SERVICE_LOG_TAG 覆盖
HZTECH_SERVICE_LOG_TAG = os.environ.get("HZTECH_SERVICE_LOG_TAG", "BaasAPI").strip() or "BaasAPI"
app = Flask(__name__)

# 本进程仅承担 API（及 /kline、/download 等）；后台定时任务（账户同步、月初、K 线夜间）由本进程在 leader 锁下启动
_BACKGROUND_SCHEDULERS_ENABLED = True

# Account_List → account_balance_snapshots / account_open_positions_snapshots / account_positions_history 同步周期（秒），默认 600（10 分钟）
try:
    _ACCOUNT_SYNC_INTERVAL_SEC = int(
        os.environ.get("HZTECH_ACCOUNT_SYNC_INTERVAL_SEC", "600").strip()
    )
except ValueError:
    _ACCOUNT_SYNC_INTERVAL_SEC = 600
_ACCOUNT_SYNC_INTERVAL_SEC = max(30, min(_ACCOUNT_SYNC_INTERVAL_SEC, 86400))

# 账户同步定时任务只启动一次，避免开发模式下重复 import / 重复注册导致同一周期跑两遍、日志交错
_account_snapshot_timer_started = False
_account_snapshot_timer_lock = threading.Lock()
_month_balance_baseline_timer_started = False
_month_balance_baseline_timer_lock = threading.Lock()
_month_balance_baseline_last_run_ym: str | None = None

# 北京日历：已对「昨天」做过 account_daily_performance 固化写入的日期键（YYYY-MM-DD = 当天北京日）
_adp_yesterday_finalize_last_bj_today: str | None = None
_adp_yesterday_finalize_timer_started = False
_adp_yesterday_finalize_timer_lock = threading.Lock()

# gunicorn 等多 worker 时仅一个进程启动后台定时器；持有锁的进程须保持文件打开直至退出
_BACKGROUND_SCHEDULER_LEADER_LOCK_FP: object | None = None
# 进程启动时写入：是否抢到了跨进程 leader 锁
_BACKGROUND_SCHEDULER_IS_LEADER: bool | None = None


def _try_acquire_background_scheduler_leader_lock() -> bool:
    """跨进程排他锁：仅 leader 进程启动账户同步 / 月初 / K 线夜间任务。

    无 fcntl 的平台（Windows）视为单进程开发环境，始终返回 True。
    锁目录默认 ``<repo>/.temp-cursor``，可用环境变量 ``HZTECH_BACKGROUND_SCHEDULER_LOCK_DIR`` 覆盖。

    日志行首含 ``[BaasAPI]``（或 ``HZTECH_SERVICE_LOG_TAG``）、时间为 ``月-日 时:分:秒``，与 FlutterApp 静态服务日志区分；
    多 worker 时请用 ``pid``/``ppid`` 或 ``GET /api/status`` 区分。
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

# 本进程启动时从 Account_List.json 插入 account_list 的新账户数（失败则为 None）
_ACCOUNT_LIST_BOOTSTRAP_INSERT_COUNT: int | None = None

# HTTP 请求计数（进程内）：负载均衡/监控会打 /api/health；浏览器 CORS 预检为 OPTIONS。
# 设为 0|false|no|off 关闭计数（略省一次锁）；汇总见 GET /api/status 字段 http_request_stats。
_API_REQUEST_STATS_DISABLED = os.environ.get(
    "HZTECH_API_REQUEST_STATS", ""
).strip().lower() in ("0", "false", "no", "off")
_API_REQUEST_STATS_LOCK = threading.Lock()
_API_REQUEST_STATS_TOTAL = 0
_API_REQUEST_STATS_NON_OPTIONS = 0
_API_REQUEST_BY_ENDPOINT: dict[str, int] = {}
_API_REQUEST_BY_STATUS_CLASS: dict[str, int] = {}


def _api_request_stats_record(resp):
    """after_request：按 Flask endpoint 与 HTTP 状态类累计（轻量，默认开启）。"""
    global _API_REQUEST_STATS_TOTAL, _API_REQUEST_STATS_NON_OPTIONS
    if _API_REQUEST_STATS_DISABLED:
        return resp
    code = int(resp.status_code or 0)
    if 200 <= code < 300:
        sk = "2xx"
    elif 300 <= code < 400:
        sk = "3xx"
    elif 400 <= code < 500:
        sk = "4xx"
    elif 500 <= code < 600:
        sk = "5xx"
    else:
        sk = "other"
    ep = request.endpoint or "_no_endpoint"
    with _API_REQUEST_STATS_LOCK:
        _API_REQUEST_STATS_TOTAL += 1
        if request.method != "OPTIONS":
            _API_REQUEST_STATS_NON_OPTIONS += 1
        _API_REQUEST_BY_ENDPOINT[ep] = _API_REQUEST_BY_ENDPOINT.get(ep, 0) + 1
        _API_REQUEST_BY_STATUS_CLASS[sk] = _API_REQUEST_BY_STATUS_CLASS.get(sk, 0) + 1
    return resp


def _api_request_stats_snapshot() -> dict:
    """供 /api/status 返回；gunicorn 多 worker 时每进程一份计数。"""
    if _API_REQUEST_STATS_DISABLED:
        return {
            "disabled": True,
            "hint": "进程内 HTTP 统计已关闭（HZTECH_API_REQUEST_STATS=0|false|no|off）",
        }
    with _API_REQUEST_STATS_LOCK:
        total = _API_REQUEST_STATS_TOTAL
        non_opt = _API_REQUEST_STATS_NON_OPTIONS
        be = dict(_API_REQUEST_BY_ENDPOINT)
        bs = dict(_API_REQUEST_BY_STATUS_CLASS)
    top = sorted(be.items(), key=lambda kv: -kv[1])[:40]
    return {
        "disabled": False,
        "since_process_start_utc": _PROCESS_START_WALL,
        "per_worker_note": (
            "本字段为当前 worker 进程内计数；gunicorn -w N 时各进程独立，"
            "请对照 process.pid。全站汇总可用 nginx 访问日志或 APM。"
        ),
        "idle_traffic_hint": (
            "即使用户未登录 App，仍可能有：负载均衡 GET /api/health、"
            "外部监控、未关浏览器页定时刷新、爬虫等。"
        ),
        "total": total,
        "non_options_total": non_opt,
        "by_status_class": bs,
        "top_endpoints": [{"endpoint": k, "count": v} for k, v in top],
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
# 持仓分段调试：DEBUG_POSITIONS=1 时输出 📍 持仓接口 / 📍 OKX 请求 等日志，便于排查界面→API→OKX
_DEBUG_POSITIONS = os.environ.get("DEBUG_POSITIONS", "0") == "1"


def _hztech_quiet_noisy_loggers(app_debug: bool) -> None:
    """压低 Watchdog/FSEvents（Flask reloader + SQLite WAL）与 urllib3 在 DEBUG 下的刷屏。"""
    for name in (
        "watchdog",
        "watchdog.observers",
        "watchdog.observers.fsevents",
        "fsevents",
    ):
        logging.getLogger(name).setLevel(logging.WARNING)
    if app_debug:
        for name in ("urllib3", "urllib3.connectionpool"):
            logging.getLogger(name).setLevel(logging.WARNING)


def apply_hztech_process_logging(service_tag: str | None = None) -> None:
    """统一控制台日志格式（行首 [BaasAPI] 等）。在 app.run 前调用，避免与 FlutterApp 日志混淆。"""
    tag = (service_tag or HZTECH_SERVICE_LOG_TAG).strip() or "BaasAPI"
    fmt = hztech_console_formatter(tag)
    level = logging.DEBUG if _LOG_LEVEL == "DEBUG" else logging.INFO
    root = logging.getLogger()
    root.setLevel(level)
    if not root.handlers:
        h = logging.StreamHandler()
        h.setFormatter(fmt)
        root.addHandler(h)
    else:
        for h in root.handlers:
            h.setFormatter(fmt)
    app.logger.setLevel(level)
    wz = logging.getLogger("werkzeug")
    # 非 DEBUG 时压低逐请求刷屏；DEBUG 与根 logger 同级
    wz.setLevel(level if _LOG_LEVEL == "DEBUG" else logging.WARNING)
    for h in wz.handlers:
        h.setFormatter(fmt)
    _hztech_quiet_noisy_loggers(_LOG_LEVEL == "DEBUG")


if _LOG_LEVEL == "DEBUG":
    _dbg_root = logging.getLogger()
    if not _dbg_root.handlers:
        _dbg_h = logging.StreamHandler()
        _dbg_h.setFormatter(hztech_console_formatter(HZTECH_SERVICE_LOG_TAG))
        _dbg_root.addHandler(_dbg_h)
    _dbg_root.setLevel(logging.DEBUG)
    app.logger.setLevel(logging.DEBUG)
    logging.getLogger("werkzeug").setLevel(logging.DEBUG)
    _hztech_quiet_noisy_loggers(True)


def _api_access_log_skip(path: str, method: str) -> bool:
    """访问摘要模式下省略高频/探测路径。"""
    if method == "GET" and path == "/api/health":
        return True
    if path.startswith("/kline/"):
        return True
    return False


def _emit_baasapi_startup_summary(port: int) -> None:
    """进程入口一行式中文摘要（图标 + 重点）。"""
    db_b = os.environ.get("HZTECH_DB_BACKEND", "postgresql").strip() or "postgresql"
    leader = globals().get("_BACKGROUND_SCHEDULER_IS_LEADER")
    if leader is True:
        lm = "🔑 定时任务　本进程为主（余额同步·月初·K 线夜间等）"
    elif leader is False:
        lm = "⏭️ 定时任务　本进程为副 worker（由持锁进程跑后台）"
    else:
        lm = "💡 定时任务　无跨进程锁或未启用后台（开发/单进程）"
    acc = os.environ.get("HZTECH_API_ACCESS_LOG", "").strip().lower() in (
        "1",
        "true",
        "yes",
    )
    if acc:
        acc_zh = "📋 已开访问摘要（HZTECH_API_ACCESS_LOG=1；略过 /api/health 与 /kline/）"
    else:
        acc_zh = "💡 需要时：HZTECH_API_ACCESS_LOG=1 打印请求一行（默认 werkzeug 静默）"
    app.logger.info("🚀 BaasAPI 就绪　🔌 端口 %s", port)
    app.logger.info("🗄️ 数据库　%s", db_b)
    app.logger.info("%s", lm)
    app.logger.info("%s", acc_zh)
    if _LOG_LEVEL == "DEBUG":
        app.logger.info("🐛 LOG_LEVEL=DEBUG　⇄ 将打印每条请求/类型摘要")
    if not _API_REQUEST_STATS_DISABLED:
        app.logger.info("📊 HTTP 计数　已开（GET /api/status → http_request_stats；关：HZTECH_API_REQUEST_STATS=0）")


@app.after_request
def _hztech_after_request_stats(resp):
    return _api_request_stats_record(resp)


@app.after_request
def _hztech_after_request_access(resp):
    """DEBUG：全量请求行；非 DEBUG 且 HZTECH_API_ACCESS_LOG=1：关键请求一行（略过健康检查与 K 线）。"""
    if _LOG_LEVEL == "DEBUG":
        app.logger.debug(
            "⇄ %s %s → %s │ %s",
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
                    app.logger.debug("⚠️ 响应为 HTML（勿当 JSON）│ %s", snippet[:200])
            except Exception:
                pass
        return resp
    if os.environ.get("HZTECH_API_ACCESS_LOG", "").strip().lower() not in (
        "1",
        "true",
        "yes",
    ):
        return resp
    if _api_access_log_skip(request.path, request.method):
        return resp
    app.logger.info(
        "📥 %s %s → %s",
        request.method,
        request.path,
        resp.status_code,
    )
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


# 项目根目录（部署根，如 /home/ec2-user/hztechapp；此为目录名，PostgreSQL 库名一般为 hztech）
PROJECT_ROOT = Path(
    os.environ.get("MOBILEAPP_ROOT", Path(__file__).resolve().parent.parent)
)
SERVER_DIR = Path(__file__).resolve().parent
CONFIG_DIR = SERVER_DIR / "accounts"
# APK 所在目录（可放多个版本），默认项目根下 apk/，对应 AWS 上 hztechapp/apk/
APK_DIR = Path(os.environ.get("APK_DIR", str(PROJECT_ROOT / "apk")))
# 资源目录：res 已移至 baasapi/res（密钥、背景图等）
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


def _admin_row_initial_capital(row: dict) -> float:
    v = row.get("Initial_capital")
    if v is None:
        v = row.get("initial_capital")
    try:
        return float(v) if v is not None else 0.0
    except (TypeError, ValueError):
        return 0.0


def _upsert_account_list_from_admin_dict(merged: dict) -> None:
    aid = str(merged.get("account_id") or "").strip()
    _db.account_list_upsert(
        aid,
        _admin_row_initial_capital(merged),
        account_name=(merged.get("account_name") or "").strip(),
        exchange_account=(merged.get("exchange_account") or "").strip(),
        symbol=(merged.get("symbol") or "").strip(),
        trading_strategy=(merged.get("trading_strategy") or "").strip(),
        account_key_file=(merged.get("account_key_file") or "").strip(),
        script_file=(merged.get("script_file") or "").strip(),
        enabled=_account_row_is_enabled(merged),
    )


def _persist_account_list_json_from_db():
    """account_list 变更后覆盖写 Account_List.json。"""
    try:
        _account_mgr.export_account_list_json_from_db(_db)
    except Exception:
        logging.exception("从 account_list 导出 Account_List.json 失败")
        return jsonify(
            {
                "success": False,
                "message": "数据库已更新但导出 Account_List.json 失败，请查看服务端日志",
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
    row = _account_mgr.account_list_row_by_id(aid)
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


def _require_admin_or_strategy_analyst():
    """收网测试：仅管理员与策略分析师。"""
    if _is_admin() or _is_strategy_analyst():
        return None
    return jsonify(
        {"success": False, "message": "仅管理员与策略分析师可使用收网测试"},
    ), 403


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
    """Account_List.json 中 account_id 对应的 OKX 密钥 JSON（baasapi/accounts/）。"""
    return _account_mgr.resolve_okx_config_path(bot_or_account_id)


def _live_equity_cash_for_bot(bot_id: str) -> tuple[float, float]:
    """当前 OKX 权益与 USDT 资产余额 cashBal（赛季起止写 final_balance / initial_balance）。"""
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
    """定时任务：Account_List 账户写入 account_balance_snapshots、
    account_open_positions_snapshots、account_positions_history（OKX positions-history 增量）；
    周期末仅 UPSERT 北京「当天」account_daily_performance（当日余额快照首末 + 当日平仓；不删历史日）。
    北京「昨天」完整按日界重算由独立凌晨定时器（北京 00:01–00:05；跨日可补跑）执行。周期由 HZTECH_ACCOUNT_SYNC_INTERVAL_SEC 控制（默认 600 秒）。"""
    

    # 账户余额同步  
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

    # 账户持仓历史同步
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

    # 账户当前持仓同步
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

    # 日线补齐
    try:
        _mb_err = _strategy_efficiency.ensure_shared_market_daily_bars(
            _db, _okx, _DEFAULT_STRATEGY_EFFICIENCY_INST_ID
        )
        if _mb_err:
            app.logger.debug("📊 日线未齐 │ %s", _mb_err)
    except Exception as _e_mdb:
        app.logger.warning("⚠️ 日线补齐异常 │ %s", _e_mdb)


    # 日绩效当日刷写
    try:
        _all_adp_ids = [
            str(b["account_id"] or "").strip()
            for b in _account_mgr.list_account_basics(enabled_only=False)
            if str(b.get("account_id") or "").strip()
        ]
        if _all_adp_ids:
            _account_mgr.refresh_account_daily_performance_today_provisional_safe(
                _db,
                _all_adp_ids,
                app.logger,
            )
    except Exception as _e_adp:
        app.logger.warning("⚠️ 日绩效·当日刷写 │ %s", _e_adp)
        try:
            _db.log_insert(
                "WARN",
                "account_daily_performance_today_refresh_failed",
                source="timer",
                extra={"error": str(_e_adp)},
            )
        except Exception:
            pass

    _sync_mark_completed(None)


def _start_account_snapshot_timer() -> None:
    """后台线程：按 HZTECH_ACCOUNT_SYNC_INTERVAL_SEC（默认 600）执行 AccountMgr 快照；启动后随机 30–60 秒首次执行。"""
    global _account_snapshot_timer_started
    with _account_snapshot_timer_lock:
        if _account_snapshot_timer_started:
            return
        _account_snapshot_timer_started = True

    def _loop() -> None:
        time.sleep(random.randint(30, 60))
        while True:
            try:
                app.logger.debug("🔄 账户同步·开始 │ pid=%s", os.getpid())
                _job_fetch_account_and_save_snapshots()
                app.logger.info(
                    "✅ 账户同步·完成 │ %ss │ pid=%s",
                    _ACCOUNT_SYNC_INTERVAL_SEC,
                    os.getpid(),
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


def _start_account_month_balance_baseline_timer() -> None:
    """北京时间每月 1 日 00:10–00:15 写入 account_month_balance_baseline；每分钟检查，同一自然月只跑一次。"""
    global _month_balance_baseline_timer_started
    with _month_balance_baseline_timer_lock:
        if _month_balance_baseline_timer_started:
            return
        _month_balance_baseline_timer_started = True

    def _loop() -> None:
        global _month_balance_baseline_last_run_ym
        time.sleep(45)
        while True:
            try:
                bj = datetime.now(ZoneInfo("Asia/Shanghai"))
                if bj.day == 1 and bj.hour == 0 and 10 <= bj.minute <= 15:
                    ym = bj.strftime("%Y-%m")
                    if _month_balance_baseline_last_run_ym != ym:
                        _account_mgr.run_account_month_balance_baseline_rollover(
                            _db, app.logger
                        )
                        _month_balance_baseline_last_run_ym = ym
            except Exception as e:
                _db.log_insert(
                    "WARN",
                    "account_month_balance_baseline_timer_error",
                    source="timer",
                    extra={"error": str(e)},
                )
            time.sleep(60)

    t = threading.Thread(target=_loop, daemon=True)
    t.start()


def _start_account_adp_yesterday_finalize_timer() -> None:
    """北京每日 00:01–00:05：对「昨天」account_daily_performance 做完整按日界重算（与账户同步周期末的当日临时 UPSERT 分离）；每分钟检查。
    冷启动（无标记）任意时刻可跑一次；若错过当日窗口且标记仍落后于当前北京日，则日间补跑一次。"""
    global _adp_yesterday_finalize_timer_started
    with _adp_yesterday_finalize_timer_lock:
        if _adp_yesterday_finalize_timer_started:
            return
        _adp_yesterday_finalize_timer_started = True

    def _loop() -> None:
        global _adp_yesterday_finalize_last_bj_today
        time.sleep(25)
        while True:
            try:
                bj = datetime.now(ZoneInfo("Asia/Shanghai"))
                bj_today = bj.strftime("%Y-%m-%d")
                if _adp_yesterday_finalize_last_bj_today == bj_today:
                    time.sleep(60)
                    continue
                in_adp_window = bj.hour == 0 and 1 <= bj.minute <= 5
                missed_new_bj_day = (
                    _adp_yesterday_finalize_last_bj_today is not None
                    and _adp_yesterday_finalize_last_bj_today < bj_today
                )
                if (
                    not in_adp_window
                    and not missed_new_bj_day
                    and _adp_yesterday_finalize_last_bj_today is not None
                ):
                    time.sleep(60)
                    continue
                yd = _db.beijing_calendar_yesterday_ymd()
                ids = [
                    str(b["account_id"] or "").strip()
                    for b in _account_mgr.list_account_basics(enabled_only=False)
                    if str(b.get("account_id") or "").strip()
                ]
                if ids:
                    _account_mgr.rebuild_account_daily_performance_days_safe(
                        _db, ids, [yd], app.logger
                    )
                _adp_yesterday_finalize_last_bj_today = bj_today
                app.logger.info("📊 日绩效·昨日固化 │ 北京昨日 %s", yd)
            except Exception as e:
                _db.log_insert(
                    "WARN",
                    "account_adp_yesterday_finalize_timer_error",
                    source="timer",
                    extra={"error": str(e)},
                )
            time.sleep(60)

    threading.Thread(target=_loop, daemon=True, name="adp_yesterday_finalize").start()


def _bootstrap_account_month_balance_baseline_if_needed_on_startup() -> None:
    """启动后延迟执行：若当月 account_month_balance_baseline 对任一可拉取余额的启用账户缺失，则仅对缺行账户补写一次。"""
    global _month_balance_baseline_last_run_ym

    time.sleep(8)
    try:
        missing_ids = (
            _account_mgr.account_month_balance_baseline_missing_account_ids_current_month(
                _db
            )
        )
        if not missing_ids:
            return
        ym = datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y-%m")
        app.logger.info(
            "📅 月初基线 │ 当月 %s 缺数·启动补写（仅 %s）",
            ym,
            ", ".join(missing_ids),
        )
        _account_mgr.run_account_month_balance_baseline_rollover(
            _db, app.logger, only_account_ids=missing_ids
        )
        _month_balance_baseline_last_run_ym = ym
    except Exception as e:
        _db.log_insert(
            "WARN",
            "account_month_balance_baseline_bootstrap_failed",
            source="timer",
            extra={"error": str(e)},
        )


# 背景图：baasapi/res/lorenz_butterfly.jpg，通过 /res/bg 访问
BG_IMAGE_FILENAME = "lorenz_butterfly.jpg"


@app.route("/res/bg")
def res_bg():
    """落地页背景图 baasapi/res/lorenz_butterfly.jpg。"""
    path = RES_DIR / BG_IMAGE_FILENAME
    if not path.is_file():
        return "", 404
    return send_file(path, mimetype="image/png", max_age=3600)


def _apk_download_response(filename: str):
    """下载 APK（仅允许 .apk 且位于 APK_DIR 内）。"""
    if not filename.endswith(".apk"):
        return jsonify({"error": "invalid file"}), 400
    path = APK_DIR / filename
    if not path.exists() or not path.is_file():
        return jsonify({"error": "not found"}), 404
    return send_file(path, as_attachment=True, download_name=filename)


@app.route("/download/apk/<filename>")
def download_apk(filename):
    return _apk_download_response(filename)


@app.route("/api/download/apk/<filename>")
def download_apk_under_api(filename):
    """与 /download/apk/ 相同；nginx 只反代 /api/ 时无需改配置即可下载。"""
    return _apk_download_response(filename)


@app.route("/", methods=["GET"])
def root_index():
    """API 根路径说明（不提供 Flutter Web SPA）。"""
    return jsonify(
        {
            "service": "hztech-api",
            "health": "/api/health",
            "hint": "Flutter Web 请使用 flutterapp/web_static/serve_web_static.py 或独立静态托管",
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
    - HZTECH_APP_ANDROID_APK：APK 文件名，默认 hztech-app-release.apk
    - HZTECH_APP_IOS_MIN / HZTECH_APP_IOS_LATEST
    - HZTECH_APP_IOS_STORE_URL：App Store / TestFlight 公开链接
    """
    apk_name = os.environ.get("HZTECH_APP_ANDROID_APK", "").strip()
    if not apk_name:
        apk_name = "hztech-app-release.apk"
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
        "后台线程按 HZTECH_ACCOUNT_SYNC_INTERVAL_SEC（默认 600 秒＝10 分钟）从 OKX 拉取 "
        "权益、资产余额(cashBal)、可用保证金、占用写入 account_balance_snapshots，当前持仓聚合写入 "
        "account_open_positions_snapshots，并拉取 positions-history 写入 account_positions_history；"
        "bills-archive 缺日补全不在此周期内，仅管理员接口、baasapi/pg_data_fill.py 或 aws-ops 远程脚本。"
        "同一周期末仅 UPSERT 北京「当天」account_daily_performance（当日平仓 + 当日快照首末差）；"
        "历史日不重算。北京「昨天」完整按日界固化由北京每日 00:01–00:05 的独立线程执行（可跨日补跑）。"
        "进程启动后随机 30–60 秒首次执行一轮。"
    )
    multi_hint = (
        "若怀疑多套定时任务在跑：在服务器执行 pgrep -af 'baasapi/main.py' 看是否多个 Python 进程；"
        "gunicorn 使用 -w N>1 时每个 worker 一个进程，仅 leader 会跑同步（见 process.background_scheduler_leader）。"
        "本地 ./baasapi/run_local.sh：默认仅 API；联调 Web 时 HZTECH_LOCAL_WEB_STATIC=1 另起 serve_web_static.py。"
    )
    try:
        _ccxt_n = _okx.ccxt_okx_exchange_cache_size()
    except Exception:
        _ccxt_n = None
    return jsonify(
        {
            "success": True,
            "uptime_seconds": up,
            "account_sync_interval_sec": _ACCOUNT_SYNC_INTERVAL_SEC,
            "sync_documentation": doc,
            "multi_process_troubleshooting": multi_hint,
            "sync": _sync_state_snapshot(),
            "process_started_at_utc": _PROCESS_START_WALL,
            "account_list_runtime_source": "database",
            "account_list_bootstrap_inserts": _ACCOUNT_LIST_BOOTSTRAP_INSERT_COUNT,
            "okx_ccxt_exchange_cache_size": _ccxt_n,
            "process": {
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "background_scheduler_leader": _BACKGROUND_SCHEDULER_IS_LEADER,
                "background_schedulers_enabled": _BACKGROUND_SCHEDULERS_ENABLED,
                "server_role": "api_server",
                "app_logger_name": app.logger.name,
            },
            "http_request_stats": _api_request_stats_snapshot(),
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
        try:
            _db.log_insert(
                "WARN",
                "login_fail",
                source="login",
                extra={"reason": "missing_username_or_password"},
            )
        except Exception:
            app.logger.warning("⚠️ 登录失败日志落库失败", exc_info=True)
        return jsonify({"success": False, "message": "请输入用户名和密码"}), 400
    if not _check_password(username, password):
        try:
            _db.log_insert(
                "WARN", "login_fail", source="login", extra={"username": username}
            )
        except Exception:
            app.logger.warning("⚠️ 登录失败日志落库失败", exc_info=True)
        return jsonify({"success": False, "message": "用户名或密码错误"}), 401
    token = _issue_token(username)
    if isinstance(token, bytes):
        token = token.decode()
    try:
        _db.log_insert(
            "INFO", "login_ok", source="login", extra={"username": username}
        )
    except Exception:
        app.logger.warning("⚠️ 登录成功日志落库失败（不影响登录）", exc_info=True)
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
    """自动收网测试桩：仅记录请求；管理员与策略分析师可调用。"""
    denied = _require_admin_or_strategy_analyst()
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
    """与 /api/account-profit 一致：数据来自 Account_List.json（AccountMgr）。

    客户仅对绑定 account_id 拉 OKX balance，避免扫全站启用账户。
    """
    allow: frozenset[str] | None = None
    if _is_customer():
        linked = _db.user_get_linked_account_ids(g.current_username)
        allow = frozenset(str(x).strip() for x in linked if str(x).strip())
    return _account_mgr.collect_accounts_profit_for_api(
        _db, account_ids_allowlist=allow
    )


# ---------- API：App 所需（与 QtraderApi 一致，需登录） ----------
@app.route("/api/account-profit", methods=["GET"])
@require_auth
def api_account_profit():
    """账户盈亏：OKX 拉取权益、USDT 资产余额(cashBal→balance_usdt)、可用保证金与占用；浮亏 upl；equity_profit_* 为权益相对期初；balance_profit_* 为资产余额相对期初；快照供曲线。"""
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
    """与 GET /api/accounts 一致：数据来自 Account_List.json。"""
    bots = _account_mgr.collect_tradingbots_style_list(strategy_status)
    ctrl = controllable_bot_ids()
    for row in bots:
        bid = (row.get("tradingbot_id") or "").strip()
        row["can_control"] = bid in ctrl
    return bots


# 交易账户列表：Account_List.json（AccountMgr）；路径 /api/accounts（策略管控见 /api/tradingbots/*/start|stop|…）
@app.route("/api/accounts", methods=["GET"])
@require_auth
def api_accounts():
    bots = _filter_bots_for_user(_collect_tradingbots_list())
    # #region agent log
    _debug_log(
        "main.py:api_accounts",
        "accounts_ok",
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


def _bot_op_response(
    resp: dict, bot_id: str, *, force_status: str | None = None
) -> dict:
    """将 bot_ctrl 返回转为 App BotOperationResponse 格式。

    force_status: 成功时固定返回的 status（如策略 stop 成功一律 stopped），避免
    响应里误带 pids 字段时被推断为仍在运行。
    """
    ok = resp.get("ok", False)
    pids = resp.get("pids") or []
    if force_status and ok:
        status = force_status
    else:
        status = "running" if ok and pids else "stopped"
    return {
        "success": ok,
        "message": resp.get("message") or resp.get("error"),
        "tradingbot_id": bot_id,
        "status": status,
    }


_BOT_CTRL_ICONS = {
    "start": "▶️",
    "stop": "⏹️",
    "restart": "🔄",
    "season_start": "📈",
    "season_stop": "📉",
}
_BOT_CTRL_LOGGER = logging.getLogger("baasapi.bot_control")


def _audit_bot_control_action(
    icon: str,
    title_cn: str,
    action_key: str,
    bot_id: str,
    *,
    ok: bool,
    username: str | None,
    detail: str | None = None,
    **extra: object,
) -> None:
    """策略/赛季管控：控制台与 logs 表双写，消息带统一 icon 便于检索与人工核对。"""
    tail = f" detail={detail}" if detail else ""
    line = f"{icon} [{title_cn}] bot_id={bot_id} ok={ok}{tail}"
    if ok:
        _BOT_CTRL_LOGGER.info(line)
    else:
        _BOT_CTRL_LOGGER.warning(line)
    payload = {
        "icon": icon,
        "action_key": action_key,
        "title_cn": title_cn,
        "bot_id": bot_id,
        "ok": ok,
        "username": username,
        "detail": detail,
        **{k: v for k, v in extra.items()},
    }
    _db.log_insert(
        "WARN" if not ok else "INFO",
        f"{icon} {title_cn}",
        "bot_control",
        extra=payload,
    )


@app.route("/api/tradingbots/<bot_id>/start", methods=["POST"])
@require_auth
def api_bot_start(bot_id):
    denied = _require_trader_or_admin()
    if denied:
        return denied
    if not _bot_is_controllable(bot_id):
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    force_raw = (request.args.get("force") or "").strip().lower()
    force = force_raw in ("1", "true", "yes", "on")
    resp = strategy_start(bot_id, force=force)
    user = getattr(g, "current_username", None)
    dr = resp.get("message") or resp.get("error") or ""
    detail = str(dr) if dr else None
    _audit_bot_control_action(
        _BOT_CTRL_ICONS["start"],
        "策略启动",
        "strategy_start",
        bot_id,
        ok=bool(resp.get("ok")),
        username=user,
        detail=detail,
        pids=resp.get("pids"),
    )
    _db.strategy_event_insert(
        bot_id,
        "start",
        "manual",
        user,
        success=bool(resp.get("ok")),
        detail=detail,
        action_icon=_BOT_CTRL_ICONS["start"],
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
    user = getattr(g, "current_username", None)
    detail_raw = resp.get("message") or resp.get("error") or ""
    detail = str(detail_raw) if detail_raw else None
    _audit_bot_control_action(
        _BOT_CTRL_ICONS["stop"],
        "策略停止",
        "strategy_stop",
        bot_id,
        ok=bool(resp.get("ok")),
        username=user,
        detail=detail,
        killed=resp.get("killed"),
    )
    _db.strategy_event_insert(
        bot_id,
        "stop",
        "manual",
        user,
        success=bool(resp.get("ok")),
        detail=detail,
        action_icon=_BOT_CTRL_ICONS["stop"],
    )
    if resp.get("ok"):
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        _db.tradingbot_mgr_session_stop(bot_id, ts, ts)
        final_eq, final_cash = _live_equity_cash_for_bot(bot_id)
        _db.account_season_update_on_stop(bot_id, ts, final_eq, final_cash)
    return jsonify(_bot_op_response(resp, bot_id, force_status="stopped"))


@app.route("/api/tradingbots/<bot_id>/restart", methods=["POST"])
@require_auth
def api_bot_restart(bot_id):
    denied = _require_trader_or_admin()
    if denied:
        return denied
    if not _bot_is_controllable(bot_id):
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    resp = strategy_restart(bot_id)
    user = getattr(g, "current_username", None)
    detail_raw = resp.get("message") or resp.get("error") or ""
    detail = str(detail_raw) if detail_raw else None
    _audit_bot_control_action(
        _BOT_CTRL_ICONS["restart"],
        "策略重启",
        "strategy_restart",
        bot_id,
        ok=bool(resp.get("ok")),
        username=user,
        detail=detail,
        pids=resp.get("pids"),
    )
    _db.strategy_event_insert(
        bot_id,
        "restart",
        "manual",
        user,
        success=bool(resp.get("ok")),
        detail=detail,
        action_icon=_BOT_CTRL_ICONS["restart"],
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
    user = getattr(g, "current_username", None)

    start_resp = None
    if not strategy_is_running(bot_id):
        start_resp = strategy_start(bot_id, force=False)
        dr = start_resp.get("message") or start_resp.get("error") or ""
        _audit_bot_control_action(
            _BOT_CTRL_ICONS["start"],
            "赛季流程·顺带拉起策略",
            "season_start_auto_bot",
            bot_id,
            ok=bool(start_resp.get("ok")),
            username=user,
            detail=str(dr) if dr else None,
            pids=start_resp.get("pids"),
        )

    if start_resp is not None and not start_resp.get("ok"):
        fail_msg = (
            start_resp.get("error")
            or start_resp.get("message")
            or "策略启动失败"
        )
        _audit_bot_control_action(
            _BOT_CTRL_ICONS["season_start"],
            "赛季启动（已中止）",
            "season_start_aborted_bot",
            bot_id,
            ok=False,
            username=user,
            detail=str(fail_msg),
        )
        _db.strategy_event_insert(
            bot_id,
            "season_start",
            "manual",
            user,
            success=False,
            detail=str(fail_msg),
            action_icon=_BOT_CTRL_ICONS["season_start"],
        )
        return jsonify(
            {
                "success": False,
                "message": fail_msg,
                "tradingbot_id": bot_id,
                "status": "stopped",
            }
        )

    shell_resp = strategy_season_start(bot_id)
    sh_err = shell_resp.get("error") or ""
    sh_msg = shell_resp.get("message") or ""
    sh_detail = str(sh_err or sh_msg) if (sh_err or sh_msg) else None
    _audit_bot_control_action(
        _BOT_CTRL_ICONS["season_start"],
        "赛季启动（shell）",
        "season_start_shell",
        bot_id,
        ok=bool(shell_resp.get("ok")),
        username=user,
        detail=sh_detail,
        start_attempted=start_resp is not None,
        start_ok=start_resp.get("ok") if start_resp else None,
    )
    ev_detail_parts: list[str] = []
    if start_resp is not None:
        ev_detail_parts.append(
            "auto_start="
            + ("ok" if start_resp.get("ok") else "fail")
        )
    ev_detail_parts.append(
        "shell=" + ("ok" if shell_resp.get("ok") else "fail")
    )
    if sh_detail:
        ev_detail_parts.append(sh_detail)
    _db.strategy_event_insert(
        bot_id,
        "season_start",
        "manual",
        user,
        success=bool(shell_resp.get("ok")),
        detail="; ".join(ev_detail_parts),
        action_icon=_BOT_CTRL_ICONS["season_start"],
    )
    running = strategy_is_running(bot_id)
    return jsonify(
        {
            "success": bool(shell_resp.get("ok")),
            "message": shell_resp.get("message")
            or (
                shell_resp.get("error")
                if not shell_resp.get("ok")
                else "赛季已启动"
            ),
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
    user = getattr(g, "current_username", None)
    dr = resp.get("message") or resp.get("error") or ""
    detail = str(dr) if dr else None
    _audit_bot_control_action(
        _BOT_CTRL_ICONS["season_stop"],
        "赛季结束",
        "season_stop_shell",
        bot_id,
        ok=bool(resp.get("ok")),
        username=user,
        detail=detail,
    )
    if resp.get("ok"):
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        eq, cash = _live_equity_cash_for_bot(bot_id)
        _db.account_season_update_on_stop(bot_id, ts, eq, cash)
    _db.strategy_event_insert(
        bot_id,
        "season_stop",
        "manual",
        user,
        success=bool(resp.get("ok")),
        detail=detail,
        action_icon=_BOT_CTRL_ICONS["season_stop"],
    )
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/accounts/<account_id>/profit-history", methods=["GET"])
@require_auth
def api_bot_profit_history(account_id):
    """机器人盈利历史（用于收益曲线图），按 snapshot_at 升序；仅 Account_List 账户。

    数据来自 account_balance_snapshots；默认仅返回自 ``since``（含）起的快照，
    避免 ORDER BY ASC LIMIT 取到最旧一段导致近月曲线为空。未传 ``since`` 时默认为 UTC 此刻起往前 45 天 00:00:00。
    Query: ``limit`` 最大返回条数（默认 15000，上限 50000）；``since`` ISO8601，如 ``2026-01-01T00:00:00.000Z``。
    """
    denied = _customer_bot_forbidden(account_id)
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
    if account_id not in account_ids:
        return (
            jsonify(
                {
                    "success": False,
                    "bot_id": account_id,
                    "message": "非 Account_List 账户，无收益快照",
                }
            ),
            400,
        )
    raw = _db.account_snapshot_query_by_account_since(
        account_id, since_snapshot_at=since, max_rows=limit
    )
    initial_bal = 0.0
    meta = _db.get_accountinfo_by_id(account_id)
    if meta:
        initial_bal = float(meta["initial_capital"])
    snapshots = [
        {
            "id": r["id"],
            "bot_id": account_id,
            "snapshot_at": r["snapshot_at"],
            "initial_balance": initial_bal,
            "current_balance": r["cash_balance"],
            "cash_balance": r["cash_balance"],
            "available_margin": r["available_margin"],
            "used_margin": r["used_margin"],
            "equity_usdt": r["equity_usdt"],
            "equity_profit_amount": r["equity_profit_amount"],
            "equity_profit_percent": r["equity_profit_percent"],
            "balance_profit_amount": r.get(
                "balance_profit_amount", r.get("cash_profit_amount", 0)
            ),
            "balance_profit_percent": r.get(
                "balance_profit_percent", r.get("cash_profit_percent", 0)
            ),
            "created_at": r["created_at"],
        }
        for r in raw
    ]
    return jsonify({"success": True, "bot_id": account_id, "snapshots": snapshots})


@app.route("/api/accounts/<account_id>/strategy-daily-efficiency", methods=["GET"])
@require_auth
def api_strategy_daily_efficiency(account_id):
    """
    策略效能：每日波动率（|高−低|/收盘%）、现金收益率%（日现金增量/UTC 自然月月初资金×100）、
    策略能效（日增量 USDT÷(波幅×1e9)）；并返回权益日增量、权益收益率%（÷月初权益）、权益能效、
    Wilder ATR(14) 及 0.1/0.6/1.2×ATR 价格阈值（经典 TR，与库字段 tr=|H−L| 不同）。
    日线 OHLC/TR 来自 market_daily_bars 全站缓存。
    现金：Account_List 账户优先 account_daily_performance.balance_changed / balance_changed_pct（北京日映射到 K 线 UTC 日），
    缺省再用 account_balance_snapshots.cash_balance 的 UTC 日末环比；月初资金优先 account_month_balance_baseline.initial_balance，
    否则用快照 cash_balance 的 UTC 月初（与回退一致）。仅支持 Account_List 账户（cash_basis=account_snapshots_cash 或有快照时）。
    无任何快照时按 K 线日期补 sod=eod=0、增量 0（cash_basis=none），仍合并计算能效（增量为 0 则能效为 0）。
    Query: inst_id=PEPE-USDT-SWAP&days=31（默认约最近一个月，按 UTC 日）
    """
    denied = _customer_bot_forbidden(account_id)
    if denied:
        return denied
    account_ids = {
        x["account_id"] for x in _account_mgr.list_account_basics(enabled_only=False)
    }
    if account_id not in account_ids:
        return (
            jsonify(
                {
                    "success": False,
                    "bot_id": account_id,
                    "message": "非 Account_List 账户，无策略效能数据",
                }
            ),
            400,
        )
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

    snaps: list = _db.account_snapshot_query_by_account_since(
        account_id, since_snapshot_at=since, max_rows=50000
    )
    cash_basis = "account_snapshots_cash" if snaps else "none"

    cash_delta_pct_override: dict[str, float] | None = None
    snap_cash_open: dict[str, float] = {}
    cash_by_day_raw = _strategy_efficiency.daily_cash_balance_eod_delta_by_utc_day(
        snaps
    )
    cash_by_day = _strategy_efficiency.fill_cash_by_day_for_market_bars(
        bars, cash_by_day_raw
    )
    month_bases = (
        _strategy_efficiency.month_start_cash_by_month_from_snapshots_cash_balance(
            snaps
        )
    )
    snap_cash_open = dict(month_bases)
    ud_list = sorted({str(b.get("day") or "") for b in bars if b.get("day")})
    pct_ov: dict[str, float] = {}
    if ud_list:
        dmin = datetime.strptime(ud_list[0], "%Y-%m-%d").replace(
            tzinfo=timezone.utc
        )
        dmax = datetime.strptime(ud_list[-1], "%Y-%m-%d").replace(
            tzinfo=timezone.utc
        )
        bj_lo = (dmin - timedelta(days=5)).strftime("%Y-%m-%d")
        bj_hi = (dmax + timedelta(days=5)).strftime("%Y-%m-%d")
        adp_rows = _db.account_daily_performance_query_day_range(
            account_id, bj_lo, bj_hi
        )
        adp_by_utc: dict[str, dict] = {}
        for row in adp_rows:
            bj = str(row.get("day") or "").strip()
            if not bj:
                continue
            ud_key = _db.utc_bar_day_for_beijing_ledger_day(bj)
            adp_by_utc[ud_key] = row
        for ud in ud_list:
            pr = adp_by_utc.get(ud)
            if not pr:
                continue
            bc = pr.get("balance_changed")
            if bc is None:
                continue
            delta = float(bc)
            base = dict(cash_by_day.get(ud) or {})
            sod = float(base.get("sod_cash") or 0.0)
            base["cash_delta_usdt"] = delta
            base["sod_cash"] = sod
            base["eod_cash"] = sod + delta
            cash_by_day[ud] = base
            bcp = pr.get("balance_changed_pct")
            if bcp is not None:
                pct_ov[ud] = float(bcp)
    cash_delta_pct_override = pct_ov if pct_ov else None

    equity_snaps: list[dict] = []
    for r in snaps:
        ts = str(r.get("snapshot_at") or "")
        eq = float(r.get("equity_usdt") or 0.0)
        equity_snaps.append({"snapshot_at": ts, "equity_usdt": eq})

    equity_by_day = _strategy_efficiency.daily_equity_delta_by_utc_day(equity_snaps)
    equity_by_day = _strategy_efficiency.fill_equity_by_day_for_market_bars(
        bars, equity_by_day
    )
    month_equity_bases = _strategy_efficiency.month_start_equity_by_month_from_snapshots(
        equity_snaps
    )

    try:
        day_strs_e = [str(b.get("day") or "") for b in bars if b.get("day")]
        min_ym = min(d[:7] for d in day_strs_e) if day_strs_e else since[:7]
    except (ValueError, TypeError, IndexError):
        min_ym = since[:7]
    mo_map = _db.account_month_balance_baseline_list_since(account_id, min_ym)
    for ym, row in mo_map.items():
        ib = row.get("initial_balance")
        if ib is not None and float(ib) > 0:
            month_bases[ym] = float(ib)
        oe = row.get("initial_equity")
        if oe is not None and float(oe) > 0:
            month_equity_bases[ym] = float(oe)
    for b in bars:
        ym = str(b.get("day") or "")[:7]
        if len(ym) < 7:
            continue
        cur_mb = month_bases.get(ym)
        if cur_mb is not None and float(cur_mb) > 0:
            continue
        v = snap_cash_open.get(ym)
        if v is not None and float(v) > 0:
            month_bases[ym] = float(v)

    bars_asc = sorted(bars, key=lambda x: str(x.get("day") or ""))
    atr14_by_day = _strategy_efficiency.compute_atr14_wilder_by_day(bars_asc)

    rows = _strategy_efficiency.merge_daily_efficiency_rows(
        bars,
        cash_by_day,
        month_bases or None,
        equity_by_day=equity_by_day,
        month_equity_base_by_month=month_equity_bases or None,
        atr14_by_day=atr14_by_day,
        cash_delta_pct_override_by_day=cash_delta_pct_override,
    )
    # merge 会覆盖 span=days+12 的 K 线，行数可能多于请求天数；仅返回最近 days 个 UTC 自然日（merge 已按日倒序；K 线与日内差分仍为 UTC 口径）
    if len(rows) > days:
        rows = rows[:days]
    return jsonify(
        {
            "success": True,
            "bot_id": account_id,
            "inst_id": inst_id,
            "day_basis": "utc",
            "cash_basis": cash_basis,
            "rows": rows,
        }
    )


@app.route("/api/accounts/<account_id>/daily-realized-pnl", methods=["GET"])
@require_auth
def api_bot_daily_realized_pnl(account_id):
    """
    历史平仓按北京时间自然日汇总（u_time_ms=OKX uTime 平仓时刻 → Asia/Shanghai 日历日），并与 account_daily_performance 合并。
    额外含 equlity_changed、balance_changed、balance_changed_pct、pnl_pct（相对当月 account_month_balance_baseline.initial_balance%）、
    instrument_id、market_truevolatility、efficiency_ratio。
    Query: year=2026&month=4
    """
    denied = _customer_bot_forbidden(account_id)
    if denied:
        return denied
    try:
        y = int(request.args.get("year", 0))
        m = int(request.args.get("month", 0))
    except (TypeError, ValueError):
        return jsonify({"success": False, "message": "year/month 无效"}), 400
    if y < 2000 or y > 2100 or m < 1 or m > 12:
        return jsonify({"success": False, "message": "year/month 超出范围"}), 400
    bid = (account_id or "").strip()
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
            r = {"day": d, "net_pnl": 0.0, "close_pos_count": 0}
        p = perf_by_day.get(d)
        if p:
            r["close_pos_count"] = int(p.get("close_pos_count") or 0)
            r["equlity_changed"] = p.get("equlity_changed")
            r["balance_changed"] = p.get("balance_changed")
            r["balance_changed_pct"] = p.get("balance_changed_pct")
            r["equity_changed_pct"] = p.get("equity_changed_pct")
            r["pnl_pct"] = p.get("pnl_pct")
            r["instrument_id"] = p.get("instrument_id")
            r["market_truevolatility"] = p.get("market_truevolatility")
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
            "day_basis": "asia_shanghai",
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


@app.route("/api/accounts/<account_id>/positions", methods=["GET"])
@require_auth
def api_bot_positions(account_id):
    """指定 bot 的当前持仓（按 account_api_file 拉 OKX），含数量、持仓成本、当前价位、动态盈亏。"""
    denied = _customer_bot_forbidden(account_id)
    if denied:
        return denied
    if _DEBUG_POSITIONS:
        app.logger.info("📍 持仓接口 │ %s", account_id)
    # #region agent log
    _debug_log(
        "main.py:api_bot_positions:entry",
        "positions request",
        {"bot_id": account_id},
        "H1",
    )
    # #endregion
    dis = _account_mgr.okx_account_disabled_exchange_reason(account_id)
    if dis:
        return jsonify(
            {
                "success": True,
                "bot_id": account_id,
                "positions": [],
                "positions_error": dis,
            }
        )
    config_path = _resolve_okx_config_path(account_id)
    # #region agent log
    _debug_log(
        "main.py:api_bot_positions:config",
        "config resolved",
        {
            "bot_id": account_id,
            "config_name": config_path.name if config_path else None,
            "config_exists": bool(config_path),
        },
        "H2",
    )
    # #endregion
    app.logger.debug(
        "📍 持仓 │ %s · cfg=%s",
        account_id,
        config_path.name if config_path else None,
    )
    if not config_path:
        return jsonify(
            {
                "success": True,
                "bot_id": account_id,
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
            "bot_id": account_id,
            "positions_len": len(positions) if positions else 0,
            "positions_error_preview": (positions_error or "")[:120],
        },
        "H2",
    )
    # #endregion
    if not positions and positions_error:
        app.logger.info("⚠️ 持仓空 │ %s │ 查 OKX/网络", account_id)
    payload: dict = {
        "success": True,
        "bot_id": account_id,
        "positions": positions,
        "positions_error": positions_error,
    }
    if positions_error and "1010" in positions_error:
        payload["okx_debug"] = _okx.okx_debug_snapshot(config_path)
    return jsonify(payload)


@app.route("/api/accounts/<account_id>/position-history", methods=["GET"])
@require_auth
def api_bot_position_history(account_id):
    """已入库的历史平仓记录（OKX positions-history 同步），按更新时间倒序分页。"""
    denied = _customer_bot_forbidden(account_id)
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
    bid = (account_id or "").strip()
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


@app.route("/api/accounts/<account_id>/position-history/sync", methods=["POST"])
@require_auth
def api_bot_position_history_sync(account_id):
    """仅管理员：立即从 OKX 拉取该 account_id 的历史仓位并入库。"""
    denied = _require_admin()
    if denied:
        return denied
    bid = (account_id or "").strip()
    ok, msg = _account_mgr.refresh_positions_history_one(_db, bid, app.logger)
    code = 200 if ok else 400
    return jsonify({"success": ok, "bot_id": bid, "message": msg}), code


@app.route("/api/accounts/<account_id>/balance-snapshot/sync", methods=["POST"])
@require_auth
def api_bot_balance_snapshot_sync(account_id):
    """
    仅管理员：从 OKX 拉取权益、USDT 资产余额(cashBal)、可用保证金、占用并入库。
    Account_List 账户 → account_balance_snapshots（equity_profit_* = 权益 − account_list.initial_capital）。
    策略效能接口按 UTC 日汇总这些快照计算日现金增量、现金收益率%、策略能效。
    """
    denied = _require_admin()
    if denied:
        return denied
    bid = (account_id or "").strip()
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


@app.route("/api/accounts/<account_id>/open-positions-snapshots", methods=["GET"])
@require_auth
def api_bot_open_positions_snapshots(account_id):
    """已入库的当前持仓聚合快照（按合约；snapshot_at 降序）。Account_List 账户。"""
    denied = _customer_bot_forbidden(account_id)
    if denied:
        return denied
    try:
        limit = int(request.args.get("limit", 200))
    except (TypeError, ValueError):
        limit = 200
    limit = max(1, min(limit, 2000))
    inst_raw = (request.args.get("inst_id") or "").strip()
    inst_f = inst_raw if inst_raw else None
    bid = (account_id or "").strip()
    rows = _db.account_open_positions_snapshots_query_by_account(
        bid, limit=limit, inst_id=inst_f
    )
    return jsonify({"success": True, "bot_id": bid, "rows": rows})


@app.route("/api/accounts/<account_id>/open-positions-snapshot/sync", methods=["POST"])
@require_auth
def api_bot_open_positions_snapshot_sync(account_id):
    """仅管理员：从 OKX 拉取当前持仓并按合约聚合写入 account_open_positions_snapshots。"""
    denied = _require_admin()
    if denied:
        return denied
    bid = (account_id or "").strip()
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
    """仅管理员：按当前 account_list.initial_capital 重算 equity_profit_*（权益）与 balance_profit_*（资产余额）。"""
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
            "message": f"已更新 {n} 条快照行的 equity_profit_amount / equity_profit_percent",
            "rows_updated": n,
        }
    )


@app.route("/api/admin/balance-snapshots/backfill-bills", methods=["POST"])
@require_auth
def api_admin_balance_snapshots_backfill_bills():
    """对 Account_List 启用账户：用 OKX 近 3 月账单中的 USDT 余额补全缺日快照（不覆盖已有日期）。

    可选 JSON Body：``{"days": 40}``，将回看自然日数限制在 7～92（默认 40，约覆盖近一月）。
    若有新插入行，会对相应账户仅临时 UPSERT 北京「当天」的 ``account_daily_performance`` 行。
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
    payload = _pg_data_fill.backfill_snapshot_okx_bills_history(
        _db, _account_mgr, app.logger, days=days
    )
    return jsonify(payload)


@app.route("/api/accounts/<account_id>/pending-orders", methods=["GET"])
@require_auth
def api_bot_pending_orders(account_id):
    """当前委托（OKX 实时，不入库）。"""
    denied = _customer_bot_forbidden(account_id)
    if denied:
        return denied
    dis = _account_mgr.okx_account_disabled_exchange_reason(account_id)
    if dis:
        return jsonify(
            {
                "success": True,
                "bot_id": account_id,
                "orders": [],
                "orders_error": dis,
            }
        )
    config_path = _resolve_okx_config_path(account_id)
    if not config_path:
        return jsonify(
            {
                "success": True,
                "bot_id": account_id,
                "orders": [],
                "orders_error": "未找到 OKX 配置",
            }
        )
    orders, err = _okx.okx_fetch_pending_orders(config_path=config_path)
    return jsonify(
        {
            "success": True,
            "bot_id": account_id,
            "orders": orders,
            "orders_error": err,
        }
    )


@app.route("/api/accounts/<account_id>/trade/execute", methods=["POST"])
@require_auth
def api_account_trade_execute(account_id):
    """Web「账号下单」：市价/限价开平、全平、多空平衡；可选 auto_tp 挂 ATR×0.1 限价止盈（日线 ATR14）。"""
    denied = _require_trader_or_admin()
    if denied:
        return denied
    denied = _customer_bot_forbidden(account_id)
    if denied:
        return denied
    aid = (account_id or "").strip()
    account_ids = {
        str(x["account_id"])
        for x in _account_mgr.list_account_basics(enabled_only=False)
        if (x.get("account_id") or "").strip()
    }
    if aid not in account_ids:
        return (
            jsonify(
                {
                    "success": False,
                    "message": "非 Account_List 账户",
                    "bot_id": aid,
                }
            ),
            400,
        )
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        body = {}
    op = body.get("op") or ""
    payload, code = _account_manual_trade.run_manual_trade_op(
        op=str(op),
        account_id=aid,
        body=body,
        account_mgr=_account_mgr,
        okx_mod=_okx,
        db_mod=_db,
        strategy_efficiency_mod=_strategy_efficiency,
    )
    return jsonify(payload), code


@app.route("/api/accounts/<account_id>/ticker", methods=["GET"])
@require_auth
def api_bot_ticker(account_id):
    """公开行情：query inst_id=BTC-USDT-SWAP（可选 symbol 自 Account_List 默认交易对）。"""
    denied = _customer_bot_forbidden(account_id)
    if denied:
        return denied
    inst_id = (request.args.get("inst_id") or "").strip()
    if not inst_id:
        for row in _account_mgr.iter_okx_accounts(enabled_only=True):
            if str(row.get("account_id") or "").strip() == account_id:
                inst_id = (row.get("symbol") or "").strip()
                break
    if not inst_id:
        return jsonify(
            {"success": False, "bot_id": account_id, "message": "缺少 inst_id 且账户无默认 symbol"}
        ), 400
    px = _okx.okx_fetch_ticker(inst_id)
    return jsonify(
        {
            "success": px is not None,
            "bot_id": account_id,
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


@app.route("/api/accounts/<account_id>/seasons", methods=["GET"])
@require_auth
def api_tradingbot_seasons(account_id):
    """赛季列表（库表 account_season；响应含 bot_id/account_id 与路径 id 一致）：启停时间、初期权益/现金、盈利。"""
    denied = _customer_bot_forbidden(account_id)
    if denied:
        return denied
    limit = min(int(request.args.get("limit", 50)), 100)
    raw = _db.account_season_list_by_account(account_id, limit=limit)
    rows = [_enrich_season_row(r) for r in raw]
    active_count = sum(1 for r in rows if r.get("is_active"))
    return jsonify(
        {
            "success": True,
            "bot_id": account_id,
            "account_id": account_id,
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


@app.route("/api/accounts/<account_id>/tradingbot-events", methods=["GET"])
@require_auth
def api_bot_tradingbot_events(account_id):
    """机器人启停事件记录（手动/自动、时间、操作人）。"""
    denied = _customer_bot_forbidden(account_id)
    if denied:
        return denied
    limit = min(int(request.args.get("limit", 50)), 200)
    rows = _db.strategy_event_query(bot_id=account_id, limit=limit)
    return jsonify({"success": True, "bot_id": account_id, "events": rows})


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
    rows = _db.account_list_list_all()
    accounts = [_account_mgr.db_row_to_account_list_json_shape(r) for r in rows]
    return jsonify({"success": True, "accounts": accounts})


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
    ok, msg = _account_list_store.validate_account_row(data)
    if not ok:
        return jsonify({"success": False, "message": msg}), 400
    if _db.get_accountinfo_by_id(aid):
        return jsonify(
            {"success": False, "message": "account_id 已存在"}
        ), 409
    try:
        _upsert_account_list_from_admin_dict(data)
    except Exception:
        logging.exception("account_list_upsert 失败")
        return jsonify({"success": False, "message": "写入数据库失败"}), 500
    err = _persist_account_list_json_from_db()
    if err:
        return err
    row = _account_mgr.account_list_row_by_id(aid)
    return jsonify({"success": True, "account": row})


@app.route("/api/admin/accounts/<account_id>", methods=["GET"])
@require_auth
def api_admin_accounts_one(account_id):
    denied = _require_admin()
    if denied:
        return denied
    row = _account_mgr.account_list_row_by_id(account_id)
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
    existing_db = _db.get_accountinfo_by_id(aid)
    if not existing_db:
        return jsonify({"success": False, "message": "未找到"}), 404
    patch = request.get_json(silent=True) or {}
    merged = {**_account_mgr.db_row_to_account_list_json_shape(existing_db), **patch}
    merged["account_id"] = aid
    ok, msg = _account_list_store.validate_account_row(merged)
    if not ok:
        return jsonify({"success": False, "message": msg}), 400
    try:
        _upsert_account_list_from_admin_dict(merged)
    except Exception:
        logging.exception("account_list_upsert 失败")
        return jsonify({"success": False, "message": "写入数据库失败"}), 500
    err = _persist_account_list_json_from_db()
    if err:
        return err
    row = _account_mgr.account_list_row_by_id(aid)
    return jsonify({"success": True, "account": row})


@app.route("/api/admin/accounts/<account_id>", methods=["DELETE"])
@require_auth
def api_admin_accounts_delete(account_id):
    denied = _require_admin()
    if denied:
        return denied
    aid = (account_id or "").strip()
    if not _db.account_list_delete(aid):
        return jsonify({"success": False, "message": "未找到"}), 404
    err = _persist_account_list_json_from_db()
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
        row = _account_mgr.account_list_row_by_id(aid)
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
    if not _account_mgr.account_list_row_by_id(aid):
        return jsonify({"success": False, "message": "服务端无此账户配置，请联系管理员维护账户列表"}), 404
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


# 启动：仅从 Account_List.json 向 account_list 插入「库中尚不存在」的账户（已有行不覆盖）；各 worker 均执行，幂等
try:
    _ACCOUNT_LIST_BOOTSTRAP_INSERT_COUNT = (
        _account_mgr.insert_new_accounts_from_account_list_json_only(_db)
    )
    if _ACCOUNT_LIST_BOOTSTRAP_INSERT_COUNT:
        app.logger.info(
            "启动·Account_List 新账户已写入 account_list │ n=%s",
            _ACCOUNT_LIST_BOOTSTRAP_INSERT_COUNT,
        )
except Exception:
    app.logger.exception("启动·从 Account_List 插入新账户失败")
    _ACCOUNT_LIST_BOOTSTRAP_INSERT_COUNT = None

# 启动定时器：AccountMgr 写入 account_balance_snapshots、account_open_positions_snapshots、
# account_positions_history（bills-archive 缺日补全仅管理员 / pg_data_fill / aws-ops 脚本）
# 夜间：PEPE（可配置）1m 标记价格 K 线写入 flutterapp/web/kline（北京约 00:07），并由 /kline/ 提供静态 JSON
# 多 worker（gunicorn 等）下用文件锁保证仅一个进程跑后台任务，避免重复同步与日志交错
if _BACKGROUND_SCHEDULERS_ENABLED:
    _bg_leader_ok = _try_acquire_background_scheduler_leader_lock()
    _BACKGROUND_SCHEDULER_IS_LEADER = _bg_leader_ok
    if _bg_leader_ok:
        app.logger.info(
            "🔑 定时·主 │ pid=%s ppid=%s │ 余额·月初·日绩效昨日·K线",
            os.getpid(),
            os.getppid(),
        )
        # 账户同步定时任务 
        _start_account_snapshot_timer()
        # 月初基线定时任务
        _start_account_month_balance_baseline_timer()
        # 日绩效昨日固化定时任务    
        _start_account_adp_yesterday_finalize_timer()
        # 启动时补写月初基线（防止月初基线缺失）
        threading.Thread(
            target=_bootstrap_account_month_balance_baseline_if_needed_on_startup,
            name="account_month_balance_baseline_bootstrap",
            daemon=True,
        ).start()

        # K 线夜间定时任务
        _kline_web_sync.start_kline_nightly_scheduler(app.logger, PROJECT_ROOT)
  
    else:
        app.logger.info(
            "⏭ 定时·副 │ 锁占用·跳过 │ pid=%s ppid=%s",
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
    apply_hztech_process_logging()
    try:
        _db.strategy_event_insert(_APP_EVENT_BOT_ID, "start", "auto", None)
    except Exception:
        pass
    atexit.register(_app_on_stop)
    signal.signal(signal.SIGTERM, _app_on_stop_signal)
    signal.signal(signal.SIGINT, _app_on_stop_signal)
    # 端口由环境变量 PORT 指定（默认 9001，与 Flutter API 预设一致）
    port = int(os.environ.get("PORT", 9001))
    _emit_baasapi_startup_summary(port)
    if os.environ.get("FLASK_DEBUG", "0") == "1":
        app.logger.info("🐛 FLASK_DEBUG=1　热重载与详细栈（生产勿开）")
    app.run(host="0.0.0.0", port=port, debug=os.environ.get("FLASK_DEBUG", "0") == "1")
