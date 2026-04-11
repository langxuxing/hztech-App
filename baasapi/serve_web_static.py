#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""兼容入口：本地仍可用 ``python3 baasapi/serve_web_static.py``。

实现与维护在 ``flutterapp/web_static/serve_web_static.py``；双机部署时 Flutter 静态机（如 aws-defi）
只同步 ``flutterapp/web_static/`` 与 ``flutterapp/build/web``、``apk/``，不同步 ``baasapi/``。
"""
from __future__ import annotations

import runpy
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
_REAL = _ROOT / "flutterapp" / "web_static" / "serve_web_static.py"

if __name__ == "__main__":
    sys.argv[0] = str(_REAL)
    runpy.run_path(str(_REAL), run_name="__main__")
