#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""仅托管 Flutter Web 构建目录（flutter build web），支持前端路由回退 index.html。

与 server/main.py 分离部署：本进程不提供 /api/*。环境变量：
- HZTECH_WEB_ROOT：静态根目录，默认当前工作目录
- PORT：监听端口，默认 9000
"""
from __future__ import annotations

import os
from pathlib import Path

from flask import Flask, abort, send_from_directory

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


def create_app(web_root: Path) -> Flask:
    app = Flask(__name__)
    root = web_root.resolve()

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
                "<code>flutter_app/build/web</code> 同步到本目录，或设置 "
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
    raw = os.environ.get("HZTECH_WEB_ROOT", ".").strip()
    web_root = Path(raw)
    if not web_root.is_absolute():
        web_root = (Path.cwd() / web_root).resolve()
    port = int(os.environ.get("PORT", "9000"))
    app = create_app(web_root)
    app.run(
        host="0.0.0.0",
        port=port,
        debug=os.environ.get("FLASK_DEBUG", "0") == "1",
    )
