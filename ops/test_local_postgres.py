#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地 PostgreSQL 连通性自检（与 baasapi 的 database_config / 环境变量约定一致）。

优先级：
  1. 环境变量 DATABASE_URL
  2. baasapi/database_config.json（若存在）
  3. baasapi/database_config.example.json（若存在）
  4. postgresql://hztech:Alpha@127.0.0.1:5432/hztech

用法：
  python3 ops/test_local_postgres.py
  DATABASE_URL=postgresql://u:p@host:5432/db python3 ops/test_local_postgres.py

连通成功后会在当前 search_path 下查询 account_list，打印全部 account_id 与 account_name。
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

OPS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = OPS_DIR.parent
BAASAPI_DIR = PROJECT_ROOT / "baasapi"


def _resolve_database_url() -> str:
    u = (os.environ.get("DATABASE_URL") or "").strip()
    if u:
        return u
    for name in ("database_config.json", "database_config.example.json"):
        p = BAASAPI_DIR / name
        if not p.is_file():
            continue
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            continue
        if isinstance(data, dict):
            url = data.get("database_url")
            if isinstance(url, str) and url.strip():
                return url.strip()
    return "postgresql://hztech:Alpha@127.0.0.1:5432/hztech"


def _resolve_postgres_schema() -> str:
    s = (os.environ.get("HZTECH_POSTGRES_SCHEMA") or "").strip()
    if s:
        return s
    for name in ("database_config.json", "database_config.example.json"):
        p = BAASAPI_DIR / name
        if not p.is_file():
            continue
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            continue
        if isinstance(data, dict):
            sch = data.get("postgres_schema")
            if isinstance(sch, str) and sch.strip():
                return sch.strip()
    return "flutterapp"


def _mask_url(url: str) -> str:
    if "@" not in url or "://" not in url:
        return url
    try:
        head, rest = url.split("://", 1)
        if "@" not in rest:
            return f"{head}://***@{rest.split('/', 1)[-1]}"
        creds, hostpart = rest.rsplit("@", 1)
        if ":" in creds:
            user = creds.split(":", 1)[0]
            return f"{head}://{user}:***@{hostpart}"
        return f"{head}://***@{hostpart}"
    except (ValueError, IndexError):
        return "<无法打码>"


def main() -> int:
    try:
        import psycopg2  # type: ignore[import-untyped]
    except ImportError:
        print(
            "错误: 未安装 psycopg2，请执行: pip install psycopg2-binary",
            file=sys.stderr,
        )
        return 1

    url = _resolve_database_url()
    schema = _resolve_postgres_schema()

    print("连接串（已打码）:", _mask_url(url))
    print("schema 检查:", schema)

    try:
        raw = psycopg2.connect(url)
    except psycopg2.Error as e:
        print("连接失败:", e, file=sys.stderr)
        return 1

    try:
        cur = raw.cursor()
        cur.execute(
            "SELECT current_user, current_database(), "
            "current_setting('server_version'), inet_server_addr() IS NOT NULL"
        )
        row = cur.fetchone()
        print("current_user:", row[0])
        print("current_database:", row[1])
        print("server_version:", row[2])
        print("inet_server_addr 非空（经 TCP）:", row[3])

        schema_esc = schema.replace('"', '""')
        cur.execute(f'SET search_path TO "{schema_esc}", public')
        cur.execute(
            "SELECT COUNT(*) FROM information_schema.tables "
            "WHERE table_schema = %s AND table_type = 'BASE TABLE'",
            (schema,),
        )
        n = cur.fetchone()[0]
        print(f'"{schema}" 下用户表数量:', n)

        try:
            cur.execute(
                """
                SELECT account_id, account_name
                FROM account_list
                ORDER BY account_id
                """
            )
            acc_rows = cur.fetchall()
        except psycopg2.Error as e:
            print("读取 account_list 失败:", e, file=sys.stderr)
            acc_rows = ()

        print("账户名称 (account_list，共 %d 条):" % len(acc_rows))
        for aid, acc_name in acc_rows:
            name = (acc_name or "").strip()
            label = name if name else "(未设置 account_name，见 account_id)"
            print(f"  {aid}\t{label}")

        cur.close()
        raw.commit()
    finally:
        raw.close()

    print("OK: 本地 PostgreSQL 连通性正常。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
