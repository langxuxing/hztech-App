#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Account_List.json 与 OKX 密钥 JSON 的解析（无网络依赖）。

运行时由 AccountMgr 等模块导入；CLI 测连用 test_account_key.py。
密钥路径：优先 OKX_Api_Key/，否则 accounts/ 根目录。
"""
from __future__ import annotations

import json
from pathlib import Path

OKXAPI_DIR = Path(__file__).resolve().parent
ACCOUNT_LIST_FILE = OKXAPI_DIR / "Account_List.json"
OKX_API_KEY_DIR = OKXAPI_DIR / "OKX_Api_Key"


def parse_enabled(value: object) -> bool:
    """解析 enbaled：与 sandbox 类似，缺省视为 True（便于列表未写该字段时仍可用）。"""
    if value is True or value == 1:
        return True
    if value is False or value == 0:
        return False
    if isinstance(value, str):
        s = value.strip().lower()
        if s in ("false", "0", "no", ""):
            return False
        return s in ("true", "1", "yes")
    if value is None:
        return True
    return bool(value)


def account_row_is_enabled(row: dict) -> bool:
    """
    Account_List 单行是否视为启用。
    优先读 enbaled（历史拼写），其次 enabled，再次 enable；均未出现时视为 True（兼容老数据）。
    """
    if "enbaled" in row:
        return parse_enabled(row.get("enbaled"))
    if "enabled" in row:
        return parse_enabled(row.get("enabled"))
    if "enable" in row:
        return parse_enabled(row.get("enable"))
    return True


def load_account_list() -> list[dict]:
    """读取 Account_List.json，返回列表；文件缺失或格式错误返回空列表。"""
    if not ACCOUNT_LIST_FILE.is_file():
        return []
    try:
        with open(ACCOUNT_LIST_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return []
    if not isinstance(data, list):
        return []
    return [x for x in data if isinstance(x, dict)]


def resolve_key_file_path(account_key_file: str) -> Path:
    """
    account_key_file 通常为 OKX_xxx.json：优先 OKX_Api_Key/，否则 accounts/ 根目录。
    """
    name = (account_key_file or "").strip()
    if not name or "/" in name or "\\" in name:
        return OKX_API_KEY_DIR / name
    primary = OKX_API_KEY_DIR / name
    if primary.is_file():
        return primary
    fallback = OKXAPI_DIR / name
    if fallback.is_file():
        return fallback
    return primary


def _parse_sandbox(value: object) -> bool:
    """
    解析 sandbox：仅 True/\"true\"/1/\"1\" 为沙盒；
    避免 \"false\" 被 bool() 误判为 True。
    """
    if value is True or value == 1:
        return True
    if value is False or value is None or value == 0:
        return False
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return False


def load_config(path: Path) -> dict | None:
    """从 JSON 加载 api 配置：name, key, secret, passphrase, base_url, sandbox。"""
    if not path.exists():
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return None
    api = data.get("api") if isinstance(data, dict) else None
    if not api or not isinstance(api, dict):
        return None
    sandbox = _parse_sandbox(api.get("sandbox"))
    base_url = (api.get("base_url") or "https://www.okx.com").rstrip("/")
    if sandbox:
        base_url = "https://www.okx.com"
    return {
        "name": api.get("name") or path.stem,
        "key": (api.get("key") or "").strip(),
        "secret": (api.get("secret") or "").strip(),
        "passphrase": (api.get("passphrase") or "").strip(),
        "base_url": base_url,
        "sandbox": sandbox,
    }
