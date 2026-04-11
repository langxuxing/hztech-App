#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""仅托管 Flutter Web 构建目录（flutter build web），支持前端路由回退 index.html。

与 baasapi/main.py（BaasAPI）分离部署：本进程不提供 /api/*。实现位于 flutterapp/web_static，
双机时 aws-defi 等 Flutter 静态机只同步本目录 + build/web + apk，不同步 baasapi/。

环境变量：
- HZTECH_WEB_ROOT：静态根目录，默认当前工作目录
- PORT：监听端口，默认 9000
- HZTECH_SERVICE_LOG_TAG：日志行首标签，默认 FlutterApp
- HZTECH_WEB_ACCESS_LOG=1：打印关键 HTTP 请求（省略 *.js 等静态资源）；默认 werkzeug 静默
- HZTECH_APK_DIR：APK 目录（可选）。未设置时依次尝试 MOBILEAPP_ROOT/apk、
  由 WEB_ROOT 推断的项目根下 apk/（flutterapp/build/web → 上溯三级到项目根）。

**直链下载（无需登录）**：注册 `GET /download/apk/<文件名>.apk`（App/Web 客户端统一短路径）与
`GET /api/download/apk/<文件名>.apk`（nginx 仅反代 `/api/` 时兼容），避免被 SPA 回退成登录页。
"""
from __future__ import annotations

import logging
import os
import sys
from pathlib import Path

# 本目录与 hztech_log_format 同包（不同步到远端时单独目录即可 import）
_web_static_dir = str(Path(__file__).resolve().parent)
if _web_static_dir not in sys.path:
    sys.path.insert(0, _web_static_dir)

from flask import Flask, abort, request, send_file, send_from_directory

try:
    from hztech_log_format import hztech_console_formatter
except ImportError:

    def hztech_console_formatter(service_tag: str) -> logging.Formatter:
        """远端若未同步 hztech_log_format.py，仍可启动（行首标签 + 月日时分秒 + 无入口 logger 名）。"""
        return logging.Formatter(
            "[%s] %%(asctime)s [%%(levelname)s] %%(message)s"
            % service_tag,
            datefmt="%m-%d %H:%M:%S",
        )

HZTECH_SERVICE_LOG_TAG = (
    os.environ.get("HZTECH_SERVICE_LOG_TAG", "FlutterApp").strip() or "FlutterApp"
)


def _hztech_quiet_noisy_loggers(app_debug: bool) -> None:
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
    """控制台日志与 BaasAPI 区分：行首 [FlutterApp]（或 HZTECH_SERVICE_LOG_TAG）。"""
    tag = (service_tag or HZTECH_SERVICE_LOG_TAG).strip() or "FlutterApp"
    fmt = hztech_console_formatter(tag)
    level = (
        logging.DEBUG
        if os.environ.get("LOG_LEVEL", "").strip().upper() == "DEBUG"
        else logging.INFO
    )
    root = logging.getLogger()
    root.setLevel(level)
    if not root.handlers:
        h = logging.StreamHandler()
        h.setFormatter(fmt)
        root.addHandler(h)
    else:
        for h in root.handlers:
            h.setFormatter(fmt)
    wz = logging.getLogger("werkzeug")
    # 默认压低 werkzeug 逐请求刷屏；DEBUG 时再开 INFO
    if os.environ.get("LOG_LEVEL", "").strip().upper() == "DEBUG":
        wz.setLevel(level)
    else:
        wz.setLevel(logging.WARNING)
    for h in wz.handlers:
        h.setFormatter(fmt)
    _hztech_quiet_noisy_loggers(
        os.environ.get("LOG_LEVEL", "").strip().upper() == "DEBUG"
    )


def _safe_file(root: Path, rel: str) -> Path | None:
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


def _is_noisy_static_path(path: str) -> bool:
    """Flutter Web 大量 js/css 资源；访问摘要日志时跳过。"""
    pl = path.lower().rstrip("/")
    if "/assets/" in pl or pl.startswith("/assets"):
        return True
    if "/canvaskit" in pl or "/icons/" in pl or pl.startswith("/fonts"):
        return True
    for suf in (
        ".js",
        ".css",
        ".map",
        ".ico",
        ".png",
        ".jpg",
        ".jpeg",
        ".webp",
        ".svg",
        ".woff",
        ".woff2",
        ".ttf",
        ".json",
        ".wasm",
    ):
        if pl.endswith(suf):
            return True
    return False


def _emit_startup_summary(logger: logging.Logger, web_root: Path, port: int) -> None:
    apk_dir = _resolve_apk_dir(web_root)
    mark = "✅" if apk_dir.is_dir() else "⚠️"
    logger.info("🚀 静态站就绪　🔌 端口 %s", port)
    logger.info("🌐 Web 根目录　%s", web_root)
    logger.info("%s APK 目录　%s", mark, apk_dir)
    logger.info("📥 直链下载　/download/apk/　与　/api/download/apk/")
    if os.environ.get("HZTECH_WEB_ACCESS_LOG", "").strip().lower() in ("1", "true", "yes"):
        logger.info("📋 已开启访问摘要（HZTECH_WEB_ACCESS_LOG=1；省略静态资源路径）")
    else:
        logger.info("💡 需要时：HZTECH_WEB_ACCESS_LOG=1 打印关键请求（默认 werkzeug 静默）")


def _resolve_apk_dir(web_root: Path) -> Path:
    raw = os.environ.get("HZTECH_APK_DIR", "").strip()
    if raw:
        p = Path(raw)
        return p.resolve() if p.is_absolute() else (Path.cwd() / p).resolve()
    mob = os.environ.get("MOBILEAPP_ROOT", "").strip()
    if mob:
        return (Path(mob) / "apk").resolve()
    wr = web_root.resolve()
    # …/flutterapp/build/web → 项目根/apk
    try:
        return (wr.parent.parent.parent / "apk").resolve()
    except (OSError, ValueError):
        return (wr / "apk").resolve()


def create_app(web_root: Path) -> Flask:
    app = Flask(__name__)
    root = web_root.resolve()

    def _apk_download(filename: str):
        if not filename.endswith(".apk"):
            abort(400)
        apk_dir = _resolve_apk_dir(root)
        if not apk_dir.is_dir():
            abort(404)
        path = (apk_dir / filename).resolve()
        try:
            path.relative_to(apk_dir.resolve())
        except ValueError:
            abort(404)
        if not path.is_file():
            abort(404)
        return send_file(path, as_attachment=True, download_name=filename)

    @app.route("/download/apk/<filename>")
    def download_apk(filename: str):
        """与 main.py 一致：仅 .apk，且必须在 APK 目录内（无需登录）。"""
        return _apk_download(filename)

    @app.route("/api/download/apk/<filename>")
    def download_apk_under_api(filename: str):
        """与 /download/apk/ 相同；nginx 只反代 /api/ 时 Web 入口仍可提供 APK。"""
        return _apk_download(filename)

    @app.route("/", defaults={"spa_path": ""})
    @app.route("/<path:spa_path>")
    def spa(spa_path: str):
        if spa_path == "api" or spa_path.startswith("api/"):
            abort(404)
        index_html = root / "index.html"
        if not index_html.is_file():
            return (
                "<!DOCTYPE html><html><head><meta charset=\"UTF-8\"><title>Web 未构建</title></head>"
                "<body style=\"font-family:system-ui;padding:2rem;\">"
                "<h1>Flutter Web 未部署</h1>"
                "<p>请在构建机执行 <code>flutter build web</code> 并将 "
                "<code>flutterapp/build/web</code> 同步到本目录，或设置 "
                "<code>HZTECH_WEB_ROOT</code>。</p></body></html>",
                503,
                {"Content-Type": "text/html; charset=utf-8"},
            )
        if not spa_path.strip("/"):
            return send_from_directory(str(root), "index.html")
        target = _safe_file(root, spa_path)
        if target is None:
            abort(404)
        if target.is_file():
            return send_from_directory(str(root), spa_path.strip("/"))
        return send_from_directory(str(root), "index.html")

    @app.after_request
    def _hztech_key_access_log(resp):
        if os.environ.get("HZTECH_WEB_ACCESS_LOG", "").strip().lower() not in (
            "1",
            "true",
            "yes",
        ):
            return resp
        if _is_noisy_static_path(request.path):
            return resp
        app.logger.info(
            "📥 %s %s → %s",
            request.method,
            request.path,
            resp.status_code,
        )
        return resp

    return app


if __name__ == "__main__":
    apply_hztech_process_logging()
    raw = os.environ.get("HZTECH_WEB_ROOT", ".").strip()
    web_root = Path(raw)
    if not web_root.is_absolute():
        web_root = (Path.cwd() / web_root).resolve()
    port = int(os.environ.get("PORT", "9000"))
    app = create_app(web_root)
    app.logger.setLevel(
        logging.DEBUG
        if os.environ.get("LOG_LEVEL", "").strip().upper() == "DEBUG"
        else logging.INFO
    )
    _emit_startup_summary(app.logger, web_root, port)
    app.run(
        host="0.0.0.0",
        port=port,
        debug=os.environ.get("FLASK_DEBUG", "0") == "1",
    )
