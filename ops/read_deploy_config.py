#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 baasapi/deploy-aws.json 读取目标配置，与 baasapi/server_mgr.target_config 一致。

供 ops/pg_ows_import.py、ops/hztech_ops_menu.sh、ops/aws_ops.sh 等调用；
非菜单子集，独立模块保留。
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import shlex
import sys
from pathlib import Path

OPS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = OPS_DIR.parent


def _cors_extra_origins_csv(c_top: dict) -> str:
    raw = c_top.get("hztech_cors_extra_origins")
    if isinstance(raw, list):
        parts = [str(x).strip() for x in raw if str(x).strip()]
        return ",".join(parts)
    if isinstance(raw, str) and raw.strip():
        return raw.strip()
    return ""


def _load_server_mgr():
    path = PROJECT_ROOT / "baasapi" / "server_mgr.py"
    spec = importlib.util.spec_from_file_location("server_mgr", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _api_listen_port(merged: dict) -> int:
    return int(
        merged.get(
            "baasapi_port",
            merged.get("app_port", merged.get("web_port", 9001)),
        )
    )


def _web_listen_port(merged: dict) -> int:
    return int(merged.get("flutterapp_port", merged.get("web_port", 9000)))


def _ssh_key_path(merged: dict) -> Path:
    sm = _load_server_mgr()
    return sm.PROJECT_ROOT / merged["key"]


def bash_export_all() -> None:
    """两台 AWS 服务各一套 SSH / URL 变量（前缀区分）。"""
    sm = _load_server_mgr()
    c_top = sm.load_config()
    scheme = str(c_top.get("scheme", "http"))
    print(f"export OPS_SCHEME={shlex.quote(scheme)}")
    print(f"export OPS_PROJECT_ROOT={shlex.quote(str(PROJECT_ROOT))}")
    for role, prefix in (("baasapi", "BAASAPI"), ("flutterapp", "FLUTTER")):
        merged = sm.target_config(role)
        key = sm.PROJECT_ROOT / merged["key"]
        ssh_port = int(merged.get("port", 22))
        user = str(merged["user"])
        host = str(merged["host"])
        remote_path = str(merged["remote_path"])
        opts = merged.get("ssh_opts") or []
        opt_parts = [shlex.quote(str(o)) for o in opts]
        print(f"export OPS_{prefix}_SSH_USER={shlex.quote(user)}")
        print(f"export OPS_{prefix}_SSH_HOST={shlex.quote(host)}")
        print(f"export OPS_{prefix}_SSH_PORT={shlex.quote(str(ssh_port))}")
        print(f"export OPS_{prefix}_SSH_KEY={shlex.quote(str(key))}")
        print(f"export OPS_{prefix}_REMOTE_PATH={shlex.quote(remote_path)}")
        arr = f"OPS_{prefix}_SSH_OPTS"
        if opt_parts:
            print(f"{arr}=( " + " ".join(opt_parts) + " )")
        else:
            print(f"{arr}=()")
        if role == "baasapi":
            p = _api_listen_port(merged)
            print(f"export OPS_{prefix}_HTTP_PORT={shlex.quote(str(p))}")
            pub = f"{scheme}://{host}:{p}"
            print(f"export OPS_{prefix}_PUBLIC_URL={shlex.quote(pub)}")
        else:
            p = _web_listen_port(merged)
            print(f"export OPS_{prefix}_HTTP_PORT={shlex.quote(str(p))}")
            pub = f"{scheme}://{host}:{p}"
            print(f"export OPS_{prefix}_PUBLIC_URL={shlex.quote(pub)}")
    cors_extra = _cors_extra_origins_csv(c_top)
    print(f"export OPS_CORS_EXTRA_ORIGINS={shlex.quote(cors_extra)}")


def bash_export(role: str) -> None:
    sm = _load_server_mgr()
    c_top = sm.load_config()
    merged = sm.target_config(role)
    scheme = str(c_top.get("scheme", "http"))
    key = _ssh_key_path(merged)
    ssh_port = int(merged.get("port", 22))
    user = str(merged["user"])
    host = str(merged["host"])
    remote_path = str(merged["remote_path"])
    opts = merged.get("ssh_opts") or []
    opt_parts = [shlex.quote(str(o)) for o in opts]
    print(f"export OPS_PROJECT_ROOT={shlex.quote(str(PROJECT_ROOT))}")
    print(f"export OPS_DEPLOY_ROLE={shlex.quote(role)}")
    print(f"export OPS_SCHEME={shlex.quote(scheme)}")
    print(f"export OPS_SSH_USER={shlex.quote(user)}")
    print(f"export OPS_SSH_HOST={shlex.quote(host)}")
    print(f"export OPS_SSH_PORT={shlex.quote(str(ssh_port))}")
    print(f"export OPS_SSH_KEY={shlex.quote(str(key))}")
    print(f"export OPS_REMOTE_PATH={shlex.quote(remote_path)}")
    if opt_parts:
        print("OPS_SSH_OPTS=( " + " ".join(opt_parts) + " )")
    else:
        print("OPS_SSH_OPTS=()")
    if role == "baasapi":
        p = _api_listen_port(merged)
        print(f"export OPS_BAASAPI_HTTP_PORT={shlex.quote(str(p))}")
        pub = f"{scheme}://{host}:{p}"
        print(f"export OPS_BAASAPI_PUBLIC_URL={shlex.quote(pub)}")
    elif role == "flutterapp":
        p = _web_listen_port(merged)
        print(f"export OPS_FLUTTER_HTTP_PORT={shlex.quote(str(p))}")
        pub = f"{scheme}://{host}:{p}"
        print(f"export OPS_FLUTTER_PUBLIC_URL={shlex.quote(pub)}")


def print_json(role: str) -> None:
    sm = _load_server_mgr()
    c_top = sm.load_config()
    merged = sm.target_config(role)
    out = {
        "scheme": c_top.get("scheme", "http"),
        "ssh_user": merged["user"],
        "ssh_host": merged["host"],
        "ssh_port": int(merged.get("port", 22)),
        "ssh_key": str(_ssh_key_path(merged)),
        "ssh_opts": list(merged.get("ssh_opts") or []),
        "remote_path": merged["remote_path"],
    }
    if role == "baasapi":
        out["http_port"] = _api_listen_port(merged)
        out["public_base_url"] = (
            f"{out['scheme']}://{out['ssh_host']}:{out['http_port']}"
        )
    else:
        out["http_port"] = _web_listen_port(merged)
        out["public_base_url"] = (
            f"{out['scheme']}://{out['ssh_host']}:{out['http_port']}"
        )
    print(json.dumps(out, ensure_ascii=False, indent=2))


def main() -> int:
    p = argparse.ArgumentParser(
        description="读取 deploy-aws.json（与 server_mgr 一致）",
    )
    p.add_argument(
        "--role",
        choices=("baasapi", "flutterapp"),
        default="baasapi",
        help="配置段（默认 baasapi = aws-alpha 后端机）",
    )
    p.add_argument(
        "--bash-export",
        action="store_true",
        help="输出可被 eval 的 export / 数组赋值（供 shell 使用）",
    )
    p.add_argument(
        "--bash-export-all",
        action="store_true",
        help="同时导出 baasapi + flutterapp 两套 OPS_* 变量",
    )
    p.add_argument("--json", action="store_true", help="打印 JSON")
    args = p.parse_args()
    if args.bash_export_all:
        bash_export_all()
        return 0
    if args.bash_export:
        bash_export(args.role)
        return 0
    if args.json:
        print_json(args.role)
        return 0
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
