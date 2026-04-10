#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""经 SSH 在 BaasAPI 主机（aws-alpha）上对本地 PostgreSQL 做只读自检。

与 ops/pg_verify_aws_alpha.sh 同源约定：远端 Postgres 监听 127.0.0.1，本机通过 ssh 在远端执行 psql。

SSH / 部署：
  默认读取 baasapi/deploy-aws.json（与 ops/read_deploy_config.py --role baasapi 一致）。
  HZTECH_SSH_PG_TARGET、HZTECH_SSH_KEY_FILE、HZTECH_SSH_OPTS 可覆盖。

远端库连接（默认与 install_postgresql_remote / db_backend 一致）：
  HZTECH_REMOTE_PG_HOST（默认 127.0.0.1）、HZTECH_REMOTE_PG_PORT（5432）、
  HZTECH_REMOTE_PG_USER（hztech）、HZTECH_REMOTE_PG_DB（hztech）、
  HZTECH_REMOTE_PG_PASSWORD 或 POSTGRES_PASSWORD（默认 Alpha）

Schema：
  HZTECH_POSTGRES_SCHEMA（默认 flutterapp）

用法：
  python3 ops/test_aws_postgres.py
  python3 ops/test_aws_postgres.py --role baasapi
  HZTECH_REMOTE_PG_PASSWORD='...' python3 ops/test_aws_postgres.py
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

OPS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = OPS_DIR.parent


def _load_deploy_json(role: str) -> dict:
    cmd = [
        sys.executable,
        str(OPS_DIR / "read_deploy_config.py"),
        "--json",
        "--role",
        role,
    ]
    out = subprocess.check_output(cmd, text=True, cwd=str(PROJECT_ROOT))
    return json.loads(out)


def _remote_pg_settings() -> tuple[str, int, str, str, str]:
    host = (os.environ.get("HZTECH_REMOTE_PG_HOST") or "127.0.0.1").strip()
    port = int((os.environ.get("HZTECH_REMOTE_PG_PORT") or "5432").strip())
    db = (os.environ.get("HZTECH_REMOTE_PG_DB") or "hztech").strip()
    user = (os.environ.get("HZTECH_REMOTE_PG_USER") or "hztech").strip()
    pw = (
        os.environ.get("HZTECH_REMOTE_PG_PASSWORD")
        or os.environ.get("POSTGRES_PASSWORD")
        or "Alpha"
    )
    return host, port, db, user, pw


def _postgres_schema() -> str:
    s = (os.environ.get("HZTECH_POSTGRES_SCHEMA") or "flutterapp").strip()
    return s or "flutterapp"


def _schema_sql_ident(schema: str) -> str:
    if not schema.replace("_", "").isalnum() or not schema[0].isalpha():
        raise ValueError(f"不安全的 schema 名: {schema!r}")
    return schema.replace('"', '""')


def _build_remote_bash(
    pg_host: str,
    pg_port: int,
    pg_db: str,
    pg_user: str,
    pg_password: str,
    schema: str,
) -> str:
    sch = _schema_sql_ident(schema)
    # 密码仅在远端 shell 中 export，不打印。
    psql_hdr = (
        f"psql -v ON_ERROR_STOP=1 -h {shlex.quote(pg_host)} "
        f"-p {pg_port} -U {shlex.quote(pg_user)} "
        f"-d {shlex.quote(pg_db)} <<'SQLEOF'"
    )
    copy_sql = (
        "\\copy (SELECT account_id, account_name FROM account_list "
        "ORDER BY account_id) TO STDOUT WITH CSV HEADER"
    )
    return (
        "set -euo pipefail\n"
        f"export PGPASSWORD={shlex.quote(pg_password)}\n"
        f"{psql_hdr}\n"
        f'SET search_path TO "{sch}", public;\n'
        "SELECT current_user AS current_user, "
        "current_database() AS current_database;\n"
        "SELECT version() AS server_version;\n"
        "SELECT COUNT(*)::int AS user_tables_in_schema\n"
        "FROM information_schema.tables\n"
        f"WHERE table_schema = '{sch}' "
        "AND table_type = 'BASE TABLE';\n"
        f"{copy_sql}\n"
        "SQLEOF\n"
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description="SSH 到 AWS BaasAPI 机验证远端 PostgreSQL",
    )
    ap.add_argument(
        "--role",
        default="baasapi",
        choices=("baasapi", "flutterapp"),
        help="deploy-aws.json 段（PostgreSQL 在 baasapi 机上，默认 baasapi）",
    )
    args = ap.parse_args()

    if args.role != "baasapi":
        print(
            "提示: PostgreSQL 通常在 baasapi 机上；"
            "flutterapp 段一般无 127.0.0.1:5432。",
            file=sys.stderr,
        )

    try:
        cfg = _load_deploy_json(args.role)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as e:
        print("读取部署配置失败:", e, file=sys.stderr)
        return 1

    key = (os.environ.get("HZTECH_SSH_KEY_FILE") or "").strip()
    key = key or cfg["ssh_key"]
    target = (os.environ.get("HZTECH_SSH_PG_TARGET") or "").strip() or (
        f'{cfg["ssh_user"]}@{cfg["ssh_host"]}'
    )
    ssh_port = int(cfg["ssh_port"])

    ssh_argv: list[str] = ["ssh"]
    for o in cfg.get("ssh_opts") or []:
        ssh_argv.append(str(o))
    extra = (os.environ.get("HZTECH_SSH_OPTS") or "").strip()
    if extra:
        ssh_argv.extend(shlex.split(extra))
    ssh_argv.extend(
        [
            "-i",
            key,
            "-p",
            str(ssh_port),
            target,
            "bash",
            "-s",
        ]
    )

    pg_host, pg_port, pg_db, pg_user, pg_password = _remote_pg_settings()
    schema = _postgres_schema()

    print("=== AWS PostgreSQL（经 SSH）===")
    print("SSH:", target, "端口", ssh_port)
    print("远端 psql:", f"{pg_user}@{pg_host}:{pg_port}/{pg_db}")
    print("search_path schema:", schema)
    print("---")
    sys.stdout.flush()

    try:
        rb = _build_remote_bash(
            pg_host, pg_port, pg_db, pg_user, pg_password, schema
        )
        r = subprocess.run(
            ssh_argv,
            input=rb.encode("utf-8"),
            capture_output=True,
            cwd=str(PROJECT_ROOT),
            check=False,
        )
    except FileNotFoundError:
        print("错误: 未找到 ssh 命令", file=sys.stderr)
        return 1
    except ValueError as e:
        print("错误:", e, file=sys.stderr)
        return 1

    if r.stderr:
        err = r.stderr.decode("utf-8", errors="replace")
        print(err, file=sys.stderr, end="")
        sys.stderr.flush()
    if r.stdout:
        out = r.stdout.decode("utf-8", errors="replace")
        print(out, end="" if out.endswith("\n") else "\n")

    if r.returncode != 0:
        msg = f"失败: ssh/psql 退出码 {r.returncode}"
        print(msg, file=sys.stderr)
        return r.returncode

    print("---")
    print("OK: AWS 上 PostgreSQL 只读检查完成。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
