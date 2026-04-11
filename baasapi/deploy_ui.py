# -*- coding: utf-8 -*-
"""部署 CLI 统一输出：中文说明 + emoji，终端需 UTF-8（macOS / Linux 默认即可）。"""

from __future__ import annotations

import sys

# --- 图标语义（扫读用）---
I_ROCKET = "🚀"
I_CLIP = "📋"
I_HAMMER = "🔨"
I_PACKAGE = "📦"
I_UPLOAD = "📤"
I_DB = "🗄️"
I_REFRESH = "🔄"
I_SEARCH = "🔍"
I_OK = "✅"
I_WARN = "⚠️"
I_ERR = "❌"
I_SKIP = "⏭️"
I_TIP = "💡"
I_DONE = "🎉"
I_LINK = "🔗"
I_TIME = "⏳"
I_PIN = "📌"
I_PHONE = "📱"
I_GLOBE = "🌐"
I_APPLE = "🍎"
I_STOP = "🛑"

# 编排阶段总数（与 deploy_orchestrator 一致）：AWS 含独立远端 pip 段为 9；本地仍为 8。
DEPLOY_STAGE_TOTAL_LOCAL = 8
DEPLOY_STAGE_TOTAL_AWS = 9
DEPLOY_STAGE_TOTAL = DEPLOY_STAGE_TOTAL_LOCAL  # 兼容旧引用


def hr(width: int = 58) -> None:
    print("─" * width)


def title(emoji: str, text: str, *, sub: str | None = None) -> None:
    print("")
    print("%s %s" % (emoji, text))
    if sub:
        print("   %s" % sub)
    hr()


def step(emoji: str, text: str) -> None:
    print("%s %s" % (emoji, text))


def title_staged(
    stage: int,
    total: int,
    emoji: str,
    text: str,
    *,
    sub: str | None = None,
) -> None:
    print("")
    print("%s 阶段 %d/%d　%s" % (emoji, stage, total, text))
    if sub:
        print("   %s" % sub)
    hr()
    sys.stdout.flush()


def stage_step(stage: int, total: int, emoji: str, text: str) -> None:
    """各阶段前空一行，便于与上一段输出区分。"""
    print("\n%s 阶段 %d/%d　%s" % (emoji, stage, total, text))
    sys.stdout.flush()


def ok(text: str) -> None:
    print("%s %s" % (I_OK, text))


def warn(text: str) -> None:
    print("%s %s" % (I_WARN, text))


def err(text: str) -> None:
    print("%s %s" % (I_ERR, text), file=sys.stderr)


def tip(text: str) -> None:
    print("%s %s" % (I_TIP, text))


def skip(text: str) -> None:
    print("%s %s" % (I_SKIP, text))


def deploy_log(text: str) -> None:
    print("%s [编排] %s" % (I_PIN, text))
