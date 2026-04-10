#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""仅托管 Flutter Web 构建目录（flutter build web），支持前端路由回退 index.html。

与 baasapi/main.py（BaasAPI）分离部署：本进程不提供 /api/*。环境变量：
- HZTECH_WEB_ROOT：静态根目录，默认当前工作目录
- PORT：监听端口，默认 9000
- HZTECH_SERVICE_LOG_TAG：日志行首标签，默认 FlutterApp
- HZTECH_APK_DIR：APK 目录（可选）。未设置时依次尝试 MOBILEAPP_ROOT/apk、
  由 WEB_ROOT 推断的项目根下 apk/（flutterapp/build/web → 上溯三级到项目根）。

**直链下载（无需登录）**：注册 `GET /download/apk/<文件名>.apk` 与 `GET /api/download/apk/<文件名>.apk`
（后者便于 nginx 仅反代 `/api/` 到 BaasAPI 时由本机静态服务代下 APK），避免被 SPA 回退成登录页。
"""
from __future__ import annotations

import logging
import os
from pathlib import Path

from flask import Flask, abort, send_file, send_from_directory

HZTECH_SERVICE_LOG_TAG = (
    os.environ.get("HZTECH_SERVICE_LOG_TAG", "FlutterApp").strip() or "FlutterApp"
)


def _hztech_log_formatter(service_tag: str) -> logging.Formatter:
    return logging.Formatter(
        f"[{service_tag}] %(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
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
    fmt = _hztech_log_formatter(tag)
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
    wz.setLevel(level)
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
    app.logger.info(
        "%s 静态服务启动 listen=0.0.0.0:%s root=%s",
        HZTECH_SERVICE_LOG_TAG,
        port,
        web_root,
    )
    app.run(
        host="0.0.0.0",
        port=port,
        debug=os.environ.get("FLASK_DEBUG", "0") == "1",
    )
