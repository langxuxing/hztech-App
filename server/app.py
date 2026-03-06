# -*- coding: utf-8 -*-
"""
MobileApp Web + API Server（部署于 AWS）
- Web：展示信息、APK 下载
- API：App 所需（QtraderApi）、策略启停、OKX 信息

App 所需 API（与 QtraderApi.kt 一致）：
  POST /api/login                 登录，Body: {username, password}，返回 {success, token}
  GET  /api/account-profit        账户盈亏（需 Bearer token）
  GET  /api/tradingbots           交易机器人列表（需 Bearer token）
  POST /api/tradingbots/{id}/start|stop|restart（需 Bearer token）
  GET  /api/logs                  日志查询（需 Bearer token，?limit=100&level=&source=）
Web/管控：
  GET  /api/strategy/status
  POST /api/strategy/start | stop | restart
  GET  /api/okx/info
"""
from __future__ import annotations

import hashlib
import os
import json
from pathlib import Path
from functools import wraps

import jwt
from flask import Flask, jsonify, request, send_file, g

import db as _db
from strategy_ctrl import start as strategy_start, stop as strategy_stop, restart as strategy_restart, status as strategy_status

app = Flask(__name__)


# CORS：允许 Flutter Web / 浏览器跨域请求 API，避免 "Failed to fetch"
@app.after_request
def _add_cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, Accept"
    return resp


@app.before_request
def _cors_preflight():
    """OPTIONS 预检请求直接返回 204，响应会经 after_request 带上 CORS 头。"""
    if request.method == "OPTIONS":
        return app.make_response(("", 204))


# 项目根目录（部署根，如 /home/ec2-user/mobileapp）
PROJECT_ROOT = Path(os.environ.get("MOBILEAPP_ROOT", Path(__file__).resolve().parent.parent))
SERVER_DIR = Path(__file__).resolve().parent
# APK 所在目录（可放多个版本），默认项目根下 apk/，对应 AWS 上 mobileapp/apk/
APK_DIR = Path(os.environ.get("APK_DIR", str(PROJECT_ROOT / "apk")))
# OKX 配置路径（仅用于 API 脱敏展示，不暴露密钥）
OKX_CONFIG_PATH = Path(os.environ.get("OKX_CONFIG", str(PROJECT_ROOT / "res" / "okx.json")))
# JWT：优先从 DB config 读，否则环境变量
_db.init_db()

def _get_jwt_secret() -> str:
    return _db.config_get("jwt_secret") or os.environ.get("JWT_SECRET", "hztech-mobileapp-secret-change-in-production")

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
    exp = datetime.datetime.utcnow() + datetime.timedelta(days=_get_jwt_exp_days())
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
            return jsonify({"success": False, "message": "未登录或 token 无效"}), 401
        g.current_username = username
        return f(*args, **kwargs)
    return wrapped


def _okx_info_safe() -> dict | None:
    """读取 OKX 配置并脱敏返回（apikey 只显示后四位，不返回 secretkey）。"""
    if not OKX_CONFIG_PATH.exists():
        return None
    try:
        with open(OKX_CONFIG_PATH, encoding="utf-8") as f:
            data = json.load(f)
        apikey = data.get("apikey", "")
        return {
            "apikey_masked": f"****{apikey[-4:]}" if len(apikey) >= 4 else "****",
            "has_passphrase": bool(data.get("passphrase")),
            "has_secretkey": bool(data.get("secretkey")),
        }
    except Exception:
        return None


# 背景图：res/洛伦兹2.png，通过 /res/bg 访问避免 URL 中文
BG_IMAGE_FILENAME = "lorenz_butterfly.jpg"


@app.route("/res/bg")
def res_bg():
    """落地页背景图 res/lorenz_butterfly.jpg。"""
    path = PROJECT_ROOT / "res" / BG_IMAGE_FILENAME
    if not path.is_file():
        return "", 404
    return send_file(path, mimetype="image/png", max_age=3600)


@app.route("/")
def index():
    """首页：洛伦兹图全屏背景，右上角「下载 App」。"""
    apk_files = []
    if APK_DIR.exists():
        for f in sorted(APK_DIR.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
            if f.suffix.lower() == ".apk":
                apk_files.append({"name": f.name, "url": f"/download/apk/{f.name}"})
    first_apk = apk_files[0] if apk_files else None
    download_url = first_apk["url"] if first_apk else "#"
    download_text = f"下载 {first_apk['name']}" if first_apk else "下载 App"
    has_bg = (PROJECT_ROOT / "res" / BG_IMAGE_FILENAME).is_file()

    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>禾正量化 | HZTech</title>
  <style>
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; min-height: 100vh; font-family: system-ui, -apple-system, sans-serif; }}
    .page {{
      position: relative;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-end;
      padding-bottom: 3rem;
      background: {"url(/res/bg) center/cover no-repeat" if has_bg else "#0f172a"};
    }}
    .page::before {{
      content: "";
      position: absolute;
      inset: 0;
      background: rgba(0,0,0,0.35);
      pointer-events: none;
    }}
    .download-app {{
      position: absolute;
      top: 1.25rem;
      right: 1.25rem;
      z-index: 2;
      padding: 0.6rem 1.1rem;
      background: rgba(255,255,255,0.95);
      color: #0f172a;
      text-decoration: none;
      font-weight: 600;
      font-size: 0.95rem;
      border-radius: 8px;
      box-shadow: 0 2px 12px rgba(0,0,0,0.15);
      transition: background 0.2s, transform 0.15s;
    }}
    .download-app:hover {{
      background: #fff;
      transform: translateY(-1px);
    }}
    .brand {{
      position: relative;
      z-index: 1;
      text-align: center;
      color: #fff;
      text-shadow: 0 1px 8px rgba(0,0,0,0.4);
      margin-top: auto;
    }}
    .brand h1 {{ font-size: clamp(1.5rem, 4vw, 2rem); margin: 0 0 0.25rem; font-weight: 600; }}
    .brand p {{ font-size: 0.9rem; opacity: 0.9; margin: 0; }}
  </style>
</head>
<body>
  <div class="page">
    <a class="download-app" href="{download_url}">{download_text}</a>
    <div class="brand">
      <h1>禾正量化</h1>
      <p>HZTech Quant</p>
    </div>
  </div>
</body>
</html>"""
    return html


@app.route("/dashboard")
def dashboard():
    """仪表盘：应用下载、服务状态、API 说明（原首页内容）。"""
    apk_files = []
    if APK_DIR.exists():
        for f in sorted(APK_DIR.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
            if f.suffix.lower() == ".apk":
                apk_files.append({"name": f.name, "url": f"/download/apk/{f.name}"})
    okx_available = OKX_CONFIG_PATH.exists()
    strategy_status_res = strategy_status()
    strategy_pids = strategy_status_res.get("pids", [])
    strategy_running = strategy_status_res.get("running", False)
    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>仪表盘 | HZTech</title>
<style>body {{ font-family: system-ui, sans-serif; max-width: 640px; margin: 2rem auto; padding: 0 1rem; }} .card {{ background: #f5f5f5; padding: 1rem; border-radius: 8px; margin: 1rem 0; }} a.dl {{ display: inline-block; padding: 0.5rem 1rem; background: #2563eb; color: #fff; text-decoration: none; border-radius: 6px; }} a.dl:hover {{ background: #1d4ed8; }} .muted {{ color: #666; font-size: 0.9rem; }}</style>
</head>
<body>
  <p><a href="/">← 返回首页</a></p>
  <section class="card"><h2>应用下载</h2><p class="muted">com.hztech.quant · 版本 1.0.0</p>
  {"".join(f'<p><a class="dl" href="{a["url"]}">下载 {a["name"]}</a></p>' for a in apk_files) or "<p class=\"muted\">暂无 APK，请将 APK 放入 apk 目录。</p>"}
  </section>
  <section class="card"><h2>服务状态</h2><p>策略: {"运行中" if strategy_running else "已停止"} (PID: {strategy_pids})</p><p>OKX: {"已配置" if okx_available else "未配置"}</p></section>
  <p class="muted">API: /api/login · /api/account-profit · /api/tradingbots · /api/logs · /api/okx/info</p>
</body>
</html>"""
    return html


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
    password = data.get("password") or ""
    if not username or not password:
        _db.log_insert("WARN", "login_fail", source="login", extra={"reason": "missing_username_or_password"})
        return jsonify({"success": False, "message": "请输入用户名和密码"}), 400
    if not _check_password(username, password):
        _db.log_insert("WARN", "login_fail", source="login", extra={"username": username})
        return jsonify({"success": False, "message": "用户名或密码错误"}), 401
    token = _issue_token(username)
    if isinstance(token, bytes):
        token = token.decode()
    _db.log_insert("INFO", "login_ok", source="login", extra={"username": username})
    return jsonify({"success": True, "token": token, "message": "ok"})


# ---------- API：App 所需（与 QtraderApi 一致，需登录） ----------
@app.route("/api/account-profit", methods=["GET"])
@require_auth
def api_account_profit():
    """账户盈亏：当前无交易所数据源，返回空列表。"""
    return jsonify({
        "success": True,
        "accounts": [],
        "total_count": 0,
    })


# 交易机器人列表：当前仅有一个管控进程 simpleserver，映射为单个 bot
@app.route("/api/tradingbots", methods=["GET"])
@require_auth
def api_tradingbots():
    st = strategy_status()
    running = st.get("running", False)
    return jsonify({
        "bots": [{
            "tradingbot_id": "simpleserver",
            "tradingbot_name": "Simpleserver（OKX 价格轮询）",
            "exchange_account": "OKX",
            "symbol": "BTC-USDT-SWAP",
            "strategy_name": "simpleserver",
            "status": "running" if running else "stopped",
            "is_running": running,
        }],
        "tradingbots": None,
        "total": 1,
    })


def _bot_op_response(resp: dict, bot_id: str = "simpleserver") -> dict:
    """将 strategy_ctrl 返回转为 App BotOperationResponse 格式。"""
    ok = resp.get("ok", False)
    return {
        "success": ok,
        "message": resp.get("message") or resp.get("error"),
        "tradingbot_id": bot_id,
        "status": "running" if ok and resp.get("pids") else resp.get("status"),
    }


@app.route("/api/tradingbots/<bot_id>/start", methods=["POST"])
@require_auth
def api_bot_start(bot_id):
    if bot_id != "simpleserver":
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    resp = strategy_start()
    _db.log_insert("INFO", "strategy_start", source="api", extra={"bot_id": bot_id, "username": getattr(g, "current_username", None), "ok": resp.get("ok")})
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/tradingbots/<bot_id>/stop", methods=["POST"])
@require_auth
def api_bot_stop(bot_id):
    if bot_id != "simpleserver":
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    resp = strategy_stop()
    _db.log_insert("INFO", "strategy_stop", source="api", extra={"bot_id": bot_id, "username": getattr(g, "current_username", None), "ok": resp.get("ok")})
    return jsonify(_bot_op_response(resp, bot_id))


@app.route("/api/tradingbots/<bot_id>/restart", methods=["POST"])
@require_auth
def api_bot_restart(bot_id):
    if bot_id != "simpleserver":
        return jsonify({"success": False, "message": "未知 bot_id"}), 404
    resp = strategy_restart()
    _db.log_insert("INFO", "strategy_restart", source="api", extra={"bot_id": bot_id, "username": getattr(g, "current_username", None), "ok": resp.get("ok")})
    return jsonify(_bot_op_response(resp, bot_id))


# ---------- API：策略（Web 管控用，与上面 bot 接口对应同一进程） ----------
@app.route("/api/strategy/status", methods=["GET"])
def api_strategy_status():
    return jsonify(strategy_status())


@app.route("/api/strategy/start", methods=["POST", "GET"])
def api_strategy_start():
    return jsonify(strategy_start())


@app.route("/api/strategy/stop", methods=["POST", "GET"])
def api_strategy_stop():
    return jsonify(strategy_stop())


@app.route("/api/strategy/restart", methods=["POST", "GET"])
def api_strategy_restart():
    return jsonify(strategy_restart())


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
    info = _okx_info_safe()
    if info is None:
        return jsonify({"ok": False, "error": "OKX 配置不存在或不可读"}), 404
    return jsonify({"ok": True, "info": info})


if __name__ == "__main__":
    # 端口约定：Web=9000，API=9001。通过环境变量 PORT 指定当前进程端口。
    # 本地与 AWS 均为双进程：Web 9000 + API 9001（见 run_local.sh / server_mgr remote_restart）
    port = int(os.environ.get("PORT", 9000))
    app.run(host="0.0.0.0", port=port, debug=os.environ.get("FLASK_DEBUG", "0") == "1")
