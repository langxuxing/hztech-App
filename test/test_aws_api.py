#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AWS API 服务测试程序：对远程 API（或本地）发真实 HTTP 请求，校验各接口。
用法：
  python test/test_aws_api.py
  BASE_URL=http://54.252.181.151:9000 python test/test_aws_api.py
  python test/test_aws_api.py -v
  python test/test_aws_api.py --user admin --password 123
不指定 BASE_URL 时从 server/deploy-aws.json 读取。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# 项目根 = test 的上级
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
SERVER_DIR = os.path.join(PROJECT_ROOT, "server")


def load_base_url() -> str:
    base = os.environ.get("BASE_URL", "").strip()
    if base:
        return base.rstrip("/")
    cfg_path = os.path.join(PROJECT_ROOT, "server", "deploy-aws.json")
    if os.path.isfile(cfg_path):
        with open(cfg_path, encoding="utf-8") as f:
            c = json.load(f)
        scheme = c.get("scheme", "http")
        api = c.get("api")
        if isinstance(api, dict) and api.get("host"):
            host = api["host"]
        else:
            host = c.get("host", "127.0.0.1")
        port = c.get("web_port", 9000)
        return f"{scheme}://{host}:{port}"
    return "http://127.0.0.1:8080"


def request(
    method: str,
    url: str,
    data: dict | None = None,
    token: str | None = None,
    timeout: int = 15,
) -> tuple[int, dict | list]:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode("utf-8") if data else None
    req = Request(url, data=body, headers=headers, method=method)
    try:
        with urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8")
            code = r.getcode()
            try:
                out = json.loads(raw)
            except json.JSONDecodeError:
                out = {"_raw": raw}
            return code, out
    except HTTPError as e:
        raw = e.read().decode("utf-8") if e.fp else "{}"
        try:
            out = json.loads(raw)
        except json.JSONDecodeError:
            out = {"_raw": raw}
        return e.code, out
    except URLError as e:
        return 0, {"_error": str(e.reason)}


def run_test(name: str, ok: bool, detail: str = "", verbose: bool = False) -> bool:
    status = "OK" if ok else "FAIL"
    print(f"  [{status}] {name}")
    if verbose and detail:
        print(f"        {detail}")
    return ok


def main() -> int:
    parser = argparse.ArgumentParser(description="AWS API 服务接口测试")
    parser.add_argument("-v", "--verbose", action="store_true", help="打印响应摘要")
    parser.add_argument("--user", default="admin", help="登录用户名")
    parser.add_argument("--password", default="123", help="登录密码")
    parser.add_argument("--base-url", default="", help="API 根 URL，覆盖 BASE_URL 与 deploy 配置")
    args = parser.parse_args()

    base = args.base_url.strip() or load_base_url()
    verbose = args.verbose
    print(f"=== AWS API 测试 @ {base}\n")

    failed = 0

    # 1) GET /
    code, body = request("GET", f"{base}/")
    ok = code == 200
    if not ok:
        failed += 1
    run_test("GET /", ok, f"code={code}" if verbose else "", verbose)

    # 2) GET /api/strategy/status（返回 ok + bots，无顶层 running）
    code, body = request("GET", f"{base}/api/strategy/status")
    ok = (
        code == 200
        and isinstance(body, dict)
        and (body.get("ok") is True or "bots" in body)
    )
    if not ok:
        failed += 1
    run_test(
        "GET /api/strategy/status", ok,
        str(body)[:80] if verbose else "", verbose
    )

    # 3) GET /api/okx/info（可能 200 或 404）
    code, body = request("GET", f"{base}/api/okx/info")
    ok = code in (200, 404)
    if not ok:
        failed += 1
    run_test("GET /api/okx/info", ok, f"code={code}" if verbose else "", verbose)

    # 4) POST /api/login 错误请求
    code, body = request(
        "POST", f"{base}/api/login", data={"username": "x", "password": ""}
    )
    ok = code in (400, 401)
    if not ok:
        failed += 1
    run_test(
        "POST /api/login (bad) -> 4xx", ok,
        f"code={code}" if verbose else "", verbose
    )

    # 5) POST /api/login 正确
    code, body = request(
        "POST", f"{base}/api/login",
        data={"username": args.user, "password": args.password},
    )
    token = None
    if code == 200 and isinstance(body, dict) and body.get("success") and body.get("token"):
        token = body["token"]
    ok = token is not None
    if not ok:
        failed += 1
    run_test(
        "POST /api/login (ok)", ok,
        "token=..." if token else str(body)[:60], verbose
    )

    if not token:
        print("\n  未获取到 token，跳过需登录接口。")
        if failed > 0:
            print(
                "  提示: 502/连接失败通常表示服务未启动或端口不对（本机 ./server/run_local.sh 默认 8080）。"
                "到 EC2 执行: cd /home/ec2-user/hztechapp && bash server/install_on_aws.sh"
            )
        print(f"=== 完成：{failed} 项失败 ===")
        return 1 if failed else 0

    # 6) GET /api/account-profit
    code, body = request("GET", f"{base}/api/account-profit", token=token)
    ok = code == 200 and isinstance(body, dict) and body.get("success") is True
    if not ok:
        failed += 1
    run_test(
        "GET /api/account-profit", ok,
        f"code={code}" if verbose else "", verbose
    )

    # 7) GET /api/tradingbots
    code, body = request("GET", f"{base}/api/tradingbots", token=token)
    ok = code == 200 and isinstance(body, dict)
    ok = ok and ("bots" in body or "tradingbots" in body)
    if not ok:
        failed += 1
    run_test(
        "GET /api/tradingbots", ok,
        f"code={code}" if verbose else "", verbose
    )

    # 8) GET /api/logs
    code, body = request("GET", f"{base}/api/logs?limit=5", token=token)
    ok = code == 200 and isinstance(body, dict)
    ok = ok and body.get("success") is True and "logs" in body
    if not ok:
        failed += 1
    run_test("GET /api/logs", ok, f"code={code}" if verbose else "", verbose)

    # 9) POST /api/tradingbots/simpleserver-lhg/start（可管控 bot 之一，仅测接口结构）
    code, body = request(
        "POST", f"{base}/api/tradingbots/simpleserver-lhg/start", token=token
    )
    ok = code == 200 and isinstance(body, dict) and "success" in body
    if not ok:
        failed += 1
    msg = (body.get("message", "") if isinstance(body, dict) else "")[:50]
    run_test(
        "POST /api/tradingbots/simpleserver-lhg/start", ok,
        msg if verbose else "", verbose
    )

    # 10) 无 token 访问应 401
    code, body = request("GET", f"{base}/api/account-profit")
    ok = code == 401
    if not ok:
        failed += 1
    run_test(
        "GET /api/account-profit (no token) -> 401", ok,
        f"code={code}" if verbose else "", verbose
    )

    if failed > 0:
        print(
            "\n  提示: 若为 502/连接错误，请到 EC2 检查并重启 API："
            " cd /home/ec2-user/hztechapp && bash server/install_on_aws.sh"
        )
    print(f"\n=== 完成：{failed} 项失败 ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
