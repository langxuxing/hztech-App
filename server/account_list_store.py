# -*- coding: utf-8 -*-
"""Account_List.json 线程安全读写（管理员 API 使用；落盘后由 main 同步 SQLite account_list）。"""

from __future__ import annotations

import json
import re
import shutil
import threading
from pathlib import Path
from typing import Any

SERVER_DIR = Path(__file__).resolve().parent
ACCOUNT_LIST_PATH = SERVER_DIR / "accounts" / "Account_List.json"

_LOCK = threading.Lock()

_ACCOUNT_ID_RE = re.compile(r"^[A-Za-z0-9_.@-]+$")


def _safe_filename(name: str) -> bool:
    n = (name or "").strip()
    if not n or "/" in n or "\\" in n or n.startswith("."):
        return False
    return True


def validate_account_row(row: dict[str, Any]) -> tuple[bool, str]:
    aid = str(row.get("account_id") or "").strip()
    if not aid:
        return False, "缺少 account_id"
    if not _ACCOUNT_ID_RE.match(aid):
        return False, "account_id 仅允许字母数字、._@-"
    ex = str(row.get("exchange_account") or "").strip().upper()
    if ex != "OKX":
        return False, "当前仅支持 exchange_account=OKX"
    keyf = str(row.get("account_key_file") or "").strip()
    if not keyf or not _safe_filename(keyf):
        return False, "account_key_file 无效（仅文件名，勿含路径）"
    sym = str(row.get("symbol") or "").strip()
    if not sym:
        return False, "缺少 symbol"
    ic = row.get("Initial_capital")
    try:
        float(ic)
    except (TypeError, ValueError):
        return False, "Initial_capital 须为数字"
    return True, ""


def load_raw() -> list[dict[str, Any]]:
    if not ACCOUNT_LIST_PATH.is_file():
        return []
    try:
        with open(ACCOUNT_LIST_PATH, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(data, list):
        return []
    return [x for x in data if isinstance(x, dict)]


def _backup() -> None:
    if ACCOUNT_LIST_PATH.is_file():
        bak = ACCOUNT_LIST_PATH.with_suffix(".json.bak")
        shutil.copy2(ACCOUNT_LIST_PATH, bak)


def _atomic_write(rows: list[dict[str, Any]]) -> None:
    ACCOUNT_LIST_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = ACCOUNT_LIST_PATH.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
        f.write("\n")
    tmp.replace(ACCOUNT_LIST_PATH)


def list_accounts() -> list[dict[str, Any]]:
    with _LOCK:
        return load_raw()


def get_account(account_id: str) -> dict[str, Any] | None:
    want = (account_id or "").strip()
    with _LOCK:
        for r in load_raw():
            if str(r.get("account_id") or "").strip() == want:
                return dict(r)
    return None


def replace_all(rows: list[dict[str, Any]]) -> None:
    for r in rows:
        ok, msg = validate_account_row(r)
        if not ok:
            raise ValueError(msg)
    ids = [str(r.get("account_id") or "").strip() for r in rows]
    if len(ids) != len(set(ids)):
        raise ValueError("account_id 重复")
    with _LOCK:
        _backup()
        _atomic_write(rows)


def upsert_account(row: dict[str, Any]) -> dict[str, Any]:
    ok, msg = validate_account_row(row)
    if not ok:
        raise ValueError(msg)
    aid = str(row.get("account_id") or "").strip()
    with _LOCK:
        cur = load_raw()
        idx = None
        for i, r in enumerate(cur):
            if str(r.get("account_id") or "").strip() == aid:
                idx = i
                break
        merged = dict(cur[idx]) if idx is not None else {}
        merged.update(row)
        merged["account_id"] = aid
        ok2, msg2 = validate_account_row(merged)
        if not ok2:
            raise ValueError(msg2)
        if idx is None:
            cur.append(merged)
        else:
            cur[idx] = merged
        _backup()
        _atomic_write(cur)
        return merged


def delete_account(account_id: str) -> bool:
    aid = (account_id or "").strip()
    with _LOCK:
        cur = load_raw()
        new = [r for r in cur if str(r.get("account_id") or "").strip() != aid]
        if len(new) == len(cur):
            return False
        _backup()
        _atomic_write(new)
        return True
