# -*- coding: utf-8 -*-
"""控制台日志：统一行首标签；werkzeug 常见英文提示改为简短中文。"""
from __future__ import annotations

import logging
import re


def werkzeug_line_zh(formatted_line: str) -> str:
    s = formatted_line
    if " werkzeug: " in s:
        s = s.replace(" werkzeug: ", " ⚡ ", 1)
    m = re.search(r"\* Detected change in ['\"]([^'\"]+)['\"],\s*reloading", s)
    if m:
        full = m.group(1)
        short = full.rsplit("/", 1)[-1] if "/" in full else full
        s = re.sub(
            r"\* Detected change in ['\"][^'\"]+['\"],\s*reloading",
            f"↻ 热重载 │ {short}", 
            s,
            count=1,
        )
    s = s.replace(
        " * Restarting with watchdog (fsevents)",
        " ↻ 进程重启 │ watchdog",
    )
    s = s.replace(" * Restarting with watchdog", " ↻ 进程重启 │ watchdog")
    s = s.replace(" * Debugger is active!", " 🐞 调试器已启用")
    s = s.replace(" * Debugger PIN: ", " 🐞 PIN ")
    return s


# 应用入口 logger 与行首 [BaasAPI]/[FlutterApp] 语义重复，控制台省略名称
_SKIP_LOGGER_NAMES = frozenset(
    {
        "main",
        "__main__",
        "baasapi.main",
        "serve_web_static",
        "baasapi.serve_web_static",
    }
)


class HztechConsoleFormatter(logging.Formatter):
    """行首标签 + 月日时分秒（无年）；入口 logger 不重复打 name；werkzeug 做中文简写。"""

    def __init__(self, service_tag: str, datefmt: str = "%m-%d %H:%M:%S") -> None:
        super().__init__(fmt="%(message)s", datefmt=datefmt)
        self.service_tag = service_tag

    def usesTime(self) -> bool:
        return True

    def format(self, record: logging.LogRecord) -> str:
        asctime = self.formatTime(record, self.datefmt)
        level = record.levelname
        msg = record.getMessage()
        if record.exc_info:
            msg = msg + "\n" + self.formatException(record.exc_info)
        elif record.stack_info:
            msg = msg + "\n" + self.formatStack(record.stack_info)
        name = record.name
        if name in _SKIP_LOGGER_NAMES:
            line = f"[{self.service_tag}] {asctime} [{level}] {msg}"
        else:
            line = f"[{self.service_tag}] {asctime} [{level}] {name}: {msg}"
        if name == "werkzeug":
            return werkzeug_line_zh(line)
        return line


def hztech_console_formatter(service_tag: str) -> logging.Formatter:
    tag = (service_tag or "BaasAPI").strip() or "BaasAPI"
    return HztechConsoleFormatter(tag)


def short_network_err_text(msg: object, max_len: int = 96) -> str:
    """把常见 requests/urllib3 异常句收成简短中文，便于控制台扫一眼。"""
    if msg is None:
        return "—"
    t = str(msg).strip()
    if not t:
        return "—"
    low = t.lower()
    if "read timed out" in low or "ReadTimeout" in type(msg).__name__:
        return "读超时"
    tn = type(msg).__name__
    if "ConnectTimeout" in tn or "connection timed out" in low:
        return "连接超时"
    if "connection refused" in low:
        return "连接被拒"
    if "failed to establish a new connection" in low:
        return "建连失败"
    if "name or service not known" in low or "nodename nor servname" in low:
        return "DNS 失败"
    if "pool is full" in low:
        return "连接池满"
    if len(t) > max_len:
        return t[: max_len - 1] + "…"
    return t
