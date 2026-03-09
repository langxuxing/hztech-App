#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
测试 OKXAPI 目录下四个账号：连接、账户信息、当前持仓。
沙盒账号需在请求头中加 x-simulated-trading: 1，base_url 均为 https://www.okx.com。
"""
import base64
import hashlib
import hmac
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import requests

OKXAPI_DIR = Path(__file__).resolve().parent
# 四份配置（与当前仓库一致）
CONFIG_FILES = [
    "OKX_Alang_Sandbox.json",
    "OKX_Hztech_Live.json",
    "OKX_Hztech_Devops.json"
]


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
    print("========== OKX 四账号测试（连接 / 账户 / 持仓）==========\n")
    all_ok = True
    for filename in CONFIG_FILES:
        path = OKXAPI_DIR / filename
        cfg = load_config(path)
        if not cfg:
            print(f"[{filename}] 跳过：文件不存在或格式无效\n")
            all_ok = False
            continue
        env_tag = " [沙盒]" if cfg["sandbox"] else " [实盘]"
        print(f"--- {cfg['name']}{env_tag} ({filename}) ---")
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
