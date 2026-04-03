#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
测试 OKX 账号密钥 JSON：连接、账户信息、当前持仓（仅依赖 api 段）。

密钥文件路径由 Account_List.json 的 account_key_file 决定，相对目录 OKX_Api_Key/
（若该路径不存在则回退尝试 Accounts 根目录，兼容旧布局）。
默认仅测试 exchange_account 为 OKX 且 enbaled 为 true 的条目；可用命令行覆盖。

沙盒账号需在请求头中加 x-simulated-trading: 1，base_url 均为 https://www.okx.com。
"""
import argparse
import base64
import hashlib
import hmac
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import requests

OKXAPI_DIR = Path(__file__).resolve().parent
ACCOUNT_LIST_FILE = OKXAPI_DIR / "Account_List.json"
OKX_API_KEY_DIR = OKXAPI_DIR / "OKX_Api_Key"


def _parse_enabled(value: object) -> bool:
    """解析 enbaled：与 sandbox 类似，缺省视为 True（便于列表未写该字段时仍跑测试）。"""
    if value is True or value == 1:
        return True
    if value is False or value == 0:
        return False
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    if value is None:
        return True
    return bool(value)


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
    account_key_file 通常为 OKX_xxx.json：优先 OKX_Api_Key/，否则 Accounts/ 根目录。
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
        if enabled_only and not _parse_enabled(row.get("enbaled")):
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


def _parse_sandbox(value: object) -> bool:
    """解析 sandbox：仅 True/\"true\"/1/\"1\" 为沙盒，避免 \"false\" 被 bool() 误判为 True。"""
    if value is True or value == 1:
        return True
    if value is False or value is None or value == 0:
        return False
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return False


def load_config(path: Path) -> dict | None:
    """从 JSON 加载 api 配置：name, key, secret, passphrase, base_url, sandbox。
    沙盒与实盘同域名，仅通过请求头 x-simulated-trading: 1 区分；sandbox=true 时 base_url 固定为 https://www.okx.com。
    """
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
    """对单个账号：测连接（balance）、读账户信息、读持仓。返回汇总结果。"""
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

    print("========== OKX 多账号测试（连接 / 账户 / 持仓）==========")
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
