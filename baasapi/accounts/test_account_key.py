#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
测试 OKX 账户密钥 JSON：连接、账户信息、当前持仓（仅依赖 api 段）。

列表与路径解析见 account_key_util；本文件仅 CLI 与 HTTP 测连。
沙盒账户需在请求头中加 x-simulated-trading: 1，base_url 均为 https://www.okx.com。
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import sys
from datetime import datetime, timezone
from pathlib import Path

import requests

try:
    from .account_key_util import (
        ACCOUNT_LIST_FILE,
        OKXAPI_DIR,
        OKX_API_KEY_DIR,
        account_row_is_enabled,
        load_account_list,
        load_config,
        resolve_key_file_path,
    )
except ImportError:  # 直接 python test_account_key.py 时无包上下文
    from account_key_util import (
        ACCOUNT_LIST_FILE,
        OKXAPI_DIR,
        OKX_API_KEY_DIR,
        account_row_is_enabled,
        load_account_list,
        load_config,
        resolve_key_file_path,
    )

# 兼容旧 import：与 account_key_util 一致
__all__ = [
    "ACCOUNT_LIST_FILE",
    "OKXAPI_DIR",
    "OKX_API_KEY_DIR",
    "account_row_is_enabled",
    "load_account_list",
    "load_config",
    "resolve_key_file_path",
    "iter_okx_test_jobs",
    "test_one_account",
]


def iter_okx_test_jobs(
    *,
    enabled_only: bool = True,
    account_id_filter: str | None = None,
) -> list[tuple[str, str, Path]]:
    """
    根据 Account_List 生成待测任务：(展示名, account_id, 密钥文件 Path)。
    同一密钥文件只保留第一次出现，避免重复请求。
    """
    entries = load_account_list()
    if not entries:
        return []

    seen_paths: set[str] = set()
    jobs: list[tuple[str, str, Path]] = []
    want_id = (account_id_filter or "").strip() or None

    for row in entries:
        if (row.get("exchange_account") or "").strip().upper() != "OKX":
            continue
        aid = str(row.get("account_id") or "").strip()
        if want_id and aid != want_id:
            continue
        if enabled_only and not account_row_is_enabled(row):
            continue
        key_name = (row.get("account_key_file") or "").strip()
        if not key_name:
            continue
        path = resolve_key_file_path(key_name)
        key_norm = str(path.resolve())
        if key_norm in seen_paths:
            continue
        seen_paths.add(key_norm)
        display = (row.get("account_name") or aid or path.stem).strip()
        jobs.append((display, aid or path.stem, path))

    return jobs


def _sign(secret: str, timestamp: str, method: str, request_path: str, body: str = "") -> str:
    """OKX v5 签名：timestamp + method + requestPath + body，HMAC SHA256 后 Base64。"""
    message = timestamp + method.upper() + request_path + body
    mac = hmac.new(
        secret.encode("utf-8"),
        message.encode("utf-8"),
        hashlib.sha256,
    )
    return base64.b64encode(mac.digest()).decode("utf-8")


def _private_get(
    base_url: str,
    request_path: str,
    key: str,
    secret: str,
    passphrase: str,
    sandbox: bool,
    params: dict | None = None,
    timeout: float = 15,
) -> dict:
    """
    发送带签名的 GET。request_path 含路径与查询串，如 /api/v5/account/balance 或 /api/v5/account/positions?instType=SWAP。
    """
    if params:
        from urllib.parse import urlencode
        request_path = request_path.split("?")[0] + "?" + urlencode(params)
    url = base_url + request_path
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    sign = _sign(secret, timestamp, "GET", request_path, "")
    headers = {
        "OK-ACCESS-KEY": key,
        "OK-ACCESS-SIGN": sign,
        "OK-ACCESS-TIMESTAMP": timestamp,
        "OK-ACCESS-PASSPHRASE": passphrase,
        "Content-Type": "application/json",
    }
    if sandbox:
        headers["x-simulated-trading"] = "1"
    r = requests.get(url, headers=headers, timeout=timeout)
    return r.json()


def test_one_account(cfg: dict) -> dict:
    """对单个账户：测连接（balance）、读账户信息、读持仓。返回汇总结果。"""
    name = cfg["name"]
    base_url = cfg["base_url"]
    key, secret, passphrase = cfg["key"], cfg["secret"], cfg["passphrase"]
    sandbox = cfg["sandbox"]
    result = {"name": name, "sandbox": sandbox, "ok": False, "balance": None, "positions": None, "error": None}

    if not key or not secret or not passphrase:
        result["error"] = "配置缺少 key/secret/passphrase"
        return result

    # 1) 连接 + 账户信息：GET /api/v5/account/balance
    try:
        balance_res = _private_get(
            base_url, "/api/v5/account/balance", key, secret, passphrase, sandbox
        )
    except Exception as e:
        result["error"] = f"balance 请求异常: {e}"
        return result

    if balance_res.get("code") != "0":
        result["error"] = f"balance 接口: code={balance_res.get('code')} msg={balance_res.get('msg', balance_res)}"
        return result

    result["balance"] = balance_res.get("data")
    result["ok"] = True

    # 2) 当前持仓：GET /api/v5/account/positions
    try:
        pos_res = _private_get(
            base_url,
            "/api/v5/account/positions",
            key,
            secret,
            passphrase,
            sandbox,
            params={"instType": "SWAP"},
        )
    except Exception as e:
        result["positions_error"] = str(e)
        result["positions"] = []
        return result

    if pos_res.get("code") != "0":
        result["positions_error"] = pos_res.get("msg", pos_res)
        result["positions"] = []
    else:
        result["positions"] = pos_res.get("data") or []

    return result


def main():
    parser = argparse.ArgumentParser(
        description="根据 Account_List.json 中的 account_key_file（OKX_Api_Key/）测试 OKX 密钥与接口。"
    )
    parser.add_argument(
        "--account",
        metavar="ACCOUNT_ID",
        help="只测试列表中该 account_id（例如 OKX_Alang_Sandbox）",
    )
    parser.add_argument(
        "--include-disabled",
        action="store_true",
        help="包含 Account_List 中 enbaled 为 false 的条目",
    )
    args = parser.parse_args()

    if not ACCOUNT_LIST_FILE.is_file():
        print(f"错误: 未找到账户列表 {ACCOUNT_LIST_FILE}", file=sys.stderr)
        sys.exit(2)

    jobs = iter_okx_test_jobs(
        enabled_only=not args.include_disabled,
        account_id_filter=args.account,
    )
    if not jobs:
        print(
            "未找到可测试的 OKX 账户：请检查 Account_List.json 中 exchange_account、"
            "enbaled、account_key_file 是否与 --account 筛选一致。\n",
            file=sys.stderr,
        )
        sys.exit(2)

    print("========== OKX 多账户测试（连接 / 账户信息 / 持仓）==========")
    print(f"账户列表: {ACCOUNT_LIST_FILE.name}，密钥目录: {OKX_API_KEY_DIR.name}/\n")

    all_ok = True
    for display_name, account_id, path in jobs:
        cfg = load_config(path)
        rel = path.relative_to(OKXAPI_DIR) if path.is_relative_to(OKXAPI_DIR) else path.name
        if not cfg:
            print(f"[{account_id}] 跳过：{rel} 不存在或 JSON 无有效 api 段\n")
            all_ok = False
            continue
        env_tag = " [沙盒]" if cfg["sandbox"] else " [实盘]"
        label = display_name or cfg["name"]
        print(f"--- {label}{env_tag} ({account_id}) [{rel}] ---")
        res = test_one_account(cfg)
        if res["error"]:
            print(f"  失败: {res['error']}\n")
            all_ok = False
            continue
        print("  连接与账户: 成功")
        if res.get("balance"):
            details = res["balance"]
            if isinstance(details, list) and details:
                total_eq = details[0].get("totalEq") or "—"
                print(f"  总权益(totalEq): {total_eq}")
            else:
                print(f"  账户数据: {details}")
        pos_list = res.get("positions") or []
        pos_err = res.get("positions_error")
        if pos_err:
            print(f"  持仓接口: {pos_err}")
        else:
            print(f"  当前持仓数: {len(pos_list)}")
            for p in pos_list[:5]:
                inst = p.get("instId", "")
                pos = p.get("pos", "")
                side = p.get("posSide", p.get("side", ""))
                print(f"    - {inst} pos={pos} side={side}")
            if len(pos_list) > 5:
                print(f"    ... 共 {len(pos_list)} 条")
        print()
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
