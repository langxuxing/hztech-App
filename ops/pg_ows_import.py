#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地 PostgreSQL → AWS BaasAPI 机（经 SSH 远端 psql）导入（默认仅导出应用 schema，与 database_config 一致）。

单文件：命令行入口与实现；亦可 ``import pg_ows_import`` 调用 ``main()``、
``build_arg_parser()`` 等。统一入口：``./ops/pg_ops.sh``。

流程：本机 pg_dump（plain SQL）经 SSH 管道到远端 psql（旧版 Bash 脚本已移除，统一用本文件）。
**默认仅导出应用 schema**：``HZTECH_APP_PG_SCHEMA``，否则与 ``HZTECH_POSTGRES_SCHEMA`` / ``database_config.json``
里 ``postgres_schema`` 一致，再否则 ``flutterapp``（EC2 目录名 ``hztechapp`` 不是 PostgreSQL schema）。全库备份用 ``--dump-full`` 或环境变量
``HZTECH_PG_DUMP_FULL=1``。全库且未显式导出 QTrader 时，会加 ``--exclude-schema=QTrader``（无该 schema 权限时避免
锁表失败）；要包含 QTrader 时设 ``HZTECH_PG_DUMP_INCLUDE_QTRADER=1``。
``HZTECH_PG_DUMP_SCHEMAS`` / ``HZTECH_PG_DUMP_EXCLUDE_SCHEMAS`` 支持逗号或空白分隔（与 pg_dump_to_aws_alpha.sh 一致）。
``HZTECH_PG_DUMP_APP_ONLY=1`` 可显式开启仅应用 schema；``HZTECH_APP_PG_SCHEMA`` 仅覆盖本次 pg_dump 的 schema 名。
约定：远端库名默认 **hztech**，连接用 schema 见 HZTECH_POSTGRES_SCHEMA（默认 flutterapp），用户 **hztech**；
目标库可用 HZTECH_REMOTE_PG_DB / --remote-db 覆盖。

本地连接（与 ops/test_local_postgres.py 一致）：
  DATABASE_URL → baasapi/database_config.json → example → 默认 127.0.0.1/hztech

远端：HZTECH_REMOTE_PG_*、POSTGRES_PASSWORD
SSH：read_deploy_config.py --role baasapi；HZTECH_SSH_PG_TARGET、HZTECH_SSH_KEY_FILE、HZTECH_SSH_OPTS

导入前默认在远端 sudo postgres 建库/角色/schema；跳过：--no-ensure-remote-db

运维菜单（网络/SSH/HTTP、本机与 AWS PG 自检）：ops/hztech_ops_menu.sh

用法：
  ./ops/pg_ops.sh
  ./ops/pg_ops.sh import --dry-run
  python3 ops/pg_ows_import.py
  python3 ops/pg_ows_import.py --dry-run
  python3 ops/pg_ows_import.py --backup-remote-first
  python3 ops/pg_ows_import.py --from-download
  python3 ops/pg_ows_import.py --from-flutterapp-pg
  python3 ops/pg_ows_import.py --from-sql /path/to/dump.sql
  python3 ops/pg_ows_import.py --dump-to .temp-cursor/local.sql
  python3 ops/pg_ows_import.py --dump-app-schema-only --dump-to .temp-cursor/app.sql
  python3 ops/pg_ows_import.py --remote-db hztechapp
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import shlex
import signal
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from shutil import which

OPS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = OPS_DIR.parent
BAASAPI_DIR = PROJECT_ROOT / "baasapi"


def resolve_local_database_url() -> str:
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


def validate_pg_ident(name: str) -> None:
    if not name:
        raise ValueError("空的数据库标识符")
    if not (name[0].isalpha() or name[0] == "_"):
        raise ValueError(f"非法的数据库标识符: {name!r}")
    for ch in name:
        if not (ch.isalnum() or ch == "_"):
            raise ValueError(f"非法的数据库标识符: {name!r}")


def remote_postgres_schema() -> str:
    s = (os.environ.get("HZTECH_POSTGRES_SCHEMA") or "flutterapp").strip()
    return s or "flutterapp"


def app_dump_pg_schema() -> str:
    """pg_dump --schema= 用的单个 schema；与 test_local_postgres 解析顺序一致（避免误用目录名 hztechapp）。"""
    s = (os.environ.get("HZTECH_APP_PG_SCHEMA") or "").strip()
    if s:
        return s
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


def schemas_from_env(var: str) -> list[str]:
    raw = (os.environ.get(var) or "").strip()
    if not raw:
        return []
    # 逗号或空白分隔（与 bash 中 HZTECH_PG_DUMP_SCHEMAS="public flutterapp" 一致）
    return [x.strip() for x in raw.replace(",", " ").split() if x.strip()]


def mask_url(url: str) -> str:
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


def load_deploy_json(role: str) -> dict:
    cmd = [
        sys.executable,
        str(OPS_DIR / "read_deploy_config.py"),
        "--json",
        "--role",
        role,
    ]
    out = subprocess.check_output(cmd, text=True, cwd=str(PROJECT_ROOT))
    return json.loads(out)


@dataclass(frozen=True)
class RemotePgConn:
    host: str
    port: int
    user: str
    password: str

    @staticmethod
    def from_env() -> RemotePgConn:
        host = (os.environ.get("HZTECH_REMOTE_PG_HOST") or "127.0.0.1").strip()
        port = int((os.environ.get("HZTECH_REMOTE_PG_PORT") or "5432").strip())
        user = (os.environ.get("HZTECH_REMOTE_PG_USER") or "hztech").strip()
        pw = (
            os.environ.get("HZTECH_REMOTE_PG_PASSWORD")
            or os.environ.get("POSTGRES_PASSWORD")
            or "Alpha"
        )
        return RemotePgConn(host=host, port=port, user=user, password=pw)


def ssh_argv(cfg: dict) -> list[str]:
    out: list[str] = ["ssh"]
    for o in cfg.get("ssh_opts") or []:
        out.append(str(o))
    extra = (os.environ.get("HZTECH_SSH_OPTS") or "").strip()
    if extra:
        out.extend(shlex.split(extra))
    key = (os.environ.get("HZTECH_SSH_KEY_FILE") or "").strip() or cfg["ssh_key"]
    target = (os.environ.get("HZTECH_SSH_PG_TARGET") or "").strip() or (
        f'{cfg["ssh_user"]}@{cfg["ssh_host"]}'
    )
    out.extend(
        [
            "-i",
            key,
            "-p",
            str(int(cfg["ssh_port"])),
            target,
        ]
    )
    return out


def pg_dump_args(
    local_url: str,
    *,
    dump_schemas: list[str] | None = None,
    exclude_schemas: list[str] | None = None,
) -> list[str]:
    cmd: list[str] = [
        "pg_dump",
        "--format=p",
        "--no-owner",
        "--no-acl",
        "--clean",
        "--if-exists",
    ]
    if dump_schemas:
        for s in dump_schemas:
            validate_pg_ident(s)
            cmd.append(f"--schema={s}")
    if exclude_schemas:
        for s in exclude_schemas:
            validate_pg_ident(s)
            cmd.append(f"--exclude-schema={s}")
    cmd.append(local_url)
    return cmd


def dry_run_ssh_line(full_ssh: list[str]) -> str:
    masked = list(full_ssh)
    for i, part in enumerate(masked):
        if part.startswith("PGPASSWORD="):
            masked[i] = "PGPASSWORD=***"
            break
    return shlex.join(masked)


def remote_psql_argv(
    pg_host: str, pg_port: int, pg_db: str, pg_user: str, pg_password: str
) -> list[str]:
    return [
        "env",
        f"PGPASSWORD={pg_password}",
        "psql",
        "-v",
        "ON_ERROR_STOP=1",
        "-h",
        pg_host,
        "-p",
        str(pg_port),
        "-U",
        pg_user,
        "-d",
        pg_db,
    ]


def run_backup_remote(
    ssh_argv_base: list[str],
    rh: str,
    rp: int,
    rdb: str,
    ru: str,
    rpw: str,
    out_path: Path,
    *,
    cwd: str,
    dump_schemas: list[str] | None = None,
    exclude_schemas: list[str] | None = None,
) -> int:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    parts: list[str] = [
        "pg_dump",
        "--format=p",
        "--no-owner",
        "--no-acl",
    ]
    if dump_schemas:
        for s in dump_schemas:
            validate_pg_ident(s)
            parts.append(f"--schema={s}")
    if exclude_schemas:
        for s in exclude_schemas:
            validate_pg_ident(s)
            parts.append(f"--exclude-schema={s}")
    pg_dump_inv = " ".join(shlex.quote(p) for p in parts)
    remote = (
        "set -euo pipefail\n"
        "command -v pg_dump >/dev/null 2>&1 || "
        '{ echo "远端未安装 pg_dump，请去掉 --backup-remote-first" >&2; exit 1; }\n'
        f"export PGPASSWORD={shlex.quote(rpw)}\n"
        f"{pg_dump_inv} "
        f"-h {shlex.quote(rh)} -p {rp} -U {shlex.quote(ru)} -d {shlex.quote(rdb)}\n"
    )
    with out_path.open("wb") as wf:
        r = subprocess.run(
            ssh_argv_base + ["bash", "-s"],
            input=remote.encode("utf-8"),
            stdout=wf,
            stderr=subprocess.PIPE,
            cwd=cwd,
            check=False,
        )
    if r.stderr:
        sys.stderr.write(r.stderr.decode("utf-8", errors="replace"))
    return r.returncode


def run_ensure_remote_database(
    ssh_base: list[str],
    *,
    pg_db: str,
    pg_user: str,
    pg_password: str,
    pg_schema: str,
    cwd: str,
) -> int:
    """经 SSH 在远端以 sudo -u postgres 建角色/库/schema（与 install_postgresql_remote 一致）。"""
    validate_pg_ident(pg_db)
    validate_pg_ident(pg_user)
    validate_pg_ident(pg_schema)
    pw_b64 = base64.b64encode(pg_password.encode("utf-8")).decode("ascii")
    remote = f"""set -euo pipefail
PG_DB='{pg_db}'
PG_USER='{pg_user}'
PG_SCHEMA='{pg_schema}'
PG_PASS="$(echo "$HZTECH_ENSURE_PG_PASS_B64" | base64 -d)"
export PG_PASS
need_sudo() {{
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@" 2>/dev/null || sudo "$@"
  fi
}}
pwd_sql_lit() {{
  python3 -c "import os; print(os.environ['PG_PASS'].replace(chr(39), chr(39)*2))"
}}
PWD_SQL=$(pwd_sql_lit)
for _ in $(seq 1 30); do
  if need_sudo -u postgres psql -tAc "select 1" &>/dev/null; then
    break
  fi
  sleep 1
done
if need_sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$PG_USER'" | grep -q 1; then
  need_sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \\"$PG_USER\\" WITH LOGIN PASSWORD '$PWD_SQL';"
else
  need_sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \\"$PG_USER\\" WITH LOGIN PASSWORD '$PWD_SQL';"
fi
if ! need_sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$PG_DB'" | grep -q 1; then
  need_sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \\"$PG_DB\\" OWNER \\"$PG_USER\\";"
fi
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \\"$PG_DB\\" OWNER TO \\"$PG_USER\\";"
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "CREATE SCHEMA IF NOT EXISTS \\"$PG_SCHEMA\\" AUTHORIZATION \\"$PG_USER\\";"
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "ALTER SCHEMA \\"$PG_SCHEMA\\" OWNER TO \\"$PG_USER\\";"
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "GRANT USAGE, CREATE ON SCHEMA \\"$PG_SCHEMA\\" TO \\"$PG_USER\\";"
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "GRANT USAGE, CREATE ON SCHEMA public TO \\"$PG_USER\\";"
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "ALTER ROLE \\"$PG_USER\\" IN DATABASE \\"$PG_DB\\" SET search_path TO \\"$PG_SCHEMA\\", public;"
"""
    cmd = ssh_base + [
        f"HZTECH_ENSURE_PG_PASS_B64={pw_b64}",
        "bash",
        "-s",
    ]
    r = subprocess.run(
        cmd,
        input=remote.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
        check=False,
    )
    if r.stdout:
        sys.stdout.write(r.stdout.decode("utf-8", errors="replace"))
    if r.stderr:
        sys.stderr.write(r.stderr.decode("utf-8", errors="replace"))
    return r.returncode


def run_psql_with_sql_file(
    full_ssh: list[str],
    sql_path: Path,
    *,
    strip_pg18_restrict: bool,
    cwd: str,
) -> subprocess.CompletedProcess:
    """将本地 plain SQL 经 stdin 送入 SSH 上的 psql。

    跳过 \\restrict/\\unrestrict、SET transaction_timeout（兼容旧 psql）。
    strip_pg18_restrict 保留参数名以兼容调用方，行为与上述过滤一致。
    """
    _ = strip_pg18_restrict
    proc = subprocess.Popen(
        full_ssh,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
    )
    assert proc.stdin is not None
    try:
        with sql_path.open("rb") as inf:
            for line in inf:
                if line.startswith(b"\\restrict") or line.startswith(b"\\unrestrict"):
                    continue
                if line.startswith(b"SET transaction_timeout"):
                    continue
                try:
                    proc.stdin.write(line)
                except BrokenPipeError:
                    break
    finally:
        try:
            proc.stdin.close()
        except BrokenPipeError:
            pass
    out, err = proc.communicate()
    return subprocess.CompletedProcess(full_ssh, proc.returncode, out, err)


def _plain_dump_stdout_filter_cmd() -> list[str]:
    """子进程：stdin→stdout，与 run_psql_with_sql_file 一致地跳过旧 psql 不认识的行。"""
    script = """import sys
_b = bytes([92])
for line in sys.stdin.buffer:
    if line.startswith(_b + b"restrict") or line.startswith(_b + b"unrestrict"):
        continue
    if line.startswith(b"SET transaction_timeout"):
        continue
    sys.stdout.buffer.write(line)
"""
    return [sys.executable, "-c", script]


def _returncode_signal_hint(rc: int) -> str:
    if rc >= 0:
        return str(rc)
    sig = -rc
    try:
        name = signal.Signals(sig).name
    except ValueError:
        return str(rc)
    if getattr(signal, "SIGPIPE", None) is not None and sig == int(signal.SIGPIPE):
        return f"{rc}（{name}：多为远端 psql 提前退出导致管道断开，请优先查看上列 psql 报错）"
    return f"{rc}（{name}）"


def run_dump_pipe_to_remote_psql(
    dump_cmd: list[str],
    full_ssh: list[str],
    cwd: str,
) -> tuple[subprocess.CompletedProcess, int]:
    """本机 pg_dump plain → 过滤 → SSH 上 psql。返回 (ssh 的 CompletedProcess, 主程序应直接返回的退出码或 0)。"""
    filt_cmd = _plain_dump_stdout_filter_cmd()
    dump_p = subprocess.Popen(
        dump_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
    )
    assert dump_p.stdout is not None
    filt_p = subprocess.Popen(
        filt_cmd,
        stdin=dump_p.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
    )
    dump_p.stdout.close()

    assert filt_p.stdout is not None
    r = subprocess.run(
        full_ssh,
        stdin=filt_p.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
        check=False,
    )
    filt_p.stdout.close()

    filt_err = filt_p.stderr.read() if filt_p.stderr else b""
    filt_rc = filt_p.wait()
    dump_err = dump_p.stderr.read() if dump_p.stderr else b""
    dump_rc = dump_p.wait()

    if r.returncode != 0:
        if r.stderr:
            sys.stderr.write(r.stderr.decode("utf-8", errors="replace"))
        print(
            f"错误: 远端 psql 导入失败（退出码 {r.returncode}）",
            file=sys.stderr,
        )
        if dump_rc != 0:
            if dump_err:
                sys.stderr.write(dump_err.decode("utf-8", errors="replace"))
            print(
                "提示: 本机 pg_dump 退出码 "
                f"{_returncode_signal_hint(dump_rc)}。",
                file=sys.stderr,
            )
        if filt_rc != 0 and filt_err:
            sys.stderr.write(filt_err.decode("utf-8", errors="replace"))
        return r, r.returncode

    if filt_rc != 0:
        if filt_err:
            sys.stderr.write(filt_err.decode("utf-8", errors="replace"))
        print(f"错误: 转储过滤子进程失败（退出码 {filt_rc}）", file=sys.stderr)
        return r, filt_rc

    if dump_rc != 0:
        if dump_err:
            sys.stderr.write(dump_err.decode("utf-8", errors="replace"))
        print(
            f"错误: 本机 pg_dump 失败（退出码 {_returncode_signal_hint(dump_rc)}）",
            file=sys.stderr,
        )
        return r, dump_rc

    if dump_err:
        sys.stderr.write(dump_err.decode("utf-8", errors="replace"))
    return r, 0


def _apply_default_dump_scope(args: argparse.Namespace) -> None:
    """无 schema/排除 子集参数时默认仅导出 app_dump_pg_schema()；全库用 --dump-full 或 HZTECH_PG_DUMP_FULL=1。"""
    if args.dump_app_schema_only or getattr(args, "dump_full", False):
        return
    if (os.environ.get("HZTECH_PG_DUMP_FULL") or "").strip().lower() in (
        "1",
        "yes",
        "true",
    ):
        args.dump_full = True
        return
    app_only_env = (os.environ.get("HZTECH_PG_DUMP_APP_ONLY") or "").strip().lower()
    if app_only_env in ("1", "yes", "true"):
        args.dump_app_schema_only = True
        return
    if app_only_env in ("0", "no", "false"):
        return
    if args.dump_schemas or schemas_from_env("HZTECH_PG_DUMP_SCHEMAS"):
        return
    if args.exclude_dump_schemas or schemas_from_env("HZTECH_PG_DUMP_EXCLUDE_SCHEMAS"):
        return
    args.dump_app_schema_only = True


def _resolve_dump_lists(args: argparse.Namespace) -> tuple[list[str], list[str]] | int:
    """返回 (dump_schemas, exclude_schemas)；配置非法时返回退出码 int。"""
    if args.dump_app_schema_only:
        if args.dump_schemas:
            print(
                "错误: --dump-app-schema-only 不能与 --dump-schema 同时使用",
                file=sys.stderr,
            )
            return 2
        if schemas_from_env("HZTECH_PG_DUMP_SCHEMAS"):
            print(
                "错误: --dump-app-schema-only 与 HZTECH_PG_DUMP_SCHEMAS 冲突",
                file=sys.stderr,
            )
            return 2
        if args.exclude_dump_schemas or schemas_from_env(
            "HZTECH_PG_DUMP_EXCLUDE_SCHEMAS"
        ):
            print(
                "错误: --dump-app-schema-only 已限定单 schema，"
                "请去掉 --exclude-dump-schema / HZTECH_PG_DUMP_EXCLUDE_SCHEMAS",
                file=sys.stderr,
            )
            return 2
        try:
            app_sch = app_dump_pg_schema()
            validate_pg_ident(app_sch)
        except ValueError as e:
            print("错误:", e, file=sys.stderr)
            return 2
        # 已用 --schema= 限定单 schema，无需再 exclude QTrader
        return [app_sch], []

    dump_list = list(args.dump_schemas or [])
    dump_list.extend(schemas_from_env("HZTECH_PG_DUMP_SCHEMAS"))
    ex_list = list(args.exclude_dump_schemas or [])
    ex_list.extend(schemas_from_env("HZTECH_PG_DUMP_EXCLUDE_SCHEMAS"))
    try:
        for s in dump_list:
            validate_pg_ident(s)
        for s in ex_list:
            validate_pg_ident(s)
    except ValueError as e:
        print("错误（--dump-schema / --exclude-dump-schema）:", e, file=sys.stderr)
        return 2
    inc_qt = (os.environ.get("HZTECH_PG_DUMP_INCLUDE_QTRADER") or "").strip().lower()
    want_qtrader_dump = inc_qt in ("1", "yes", "true")
    if not want_qtrader_dump and "QTrader" not in dump_list and "QTrader" not in ex_list:
        ex_list.insert(0, "QTrader")
    return dump_list, ex_list


def _resolve_sql_paths(
    args: argparse.Namespace,
    *,
    project_root: Path,
) -> tuple[Path | None, Path | None, int | None]:
    """返回 (dump_to_path, sql_import_path, error_code)。error_code 非 None 时应直接退出。"""
    src_n = (
        int(bool(args.from_sql))
        + int(bool(args.from_download))
        + int(bool(args.from_flutterapp_pg))
    )
    if src_n > 1:
        print(
            "错误: --from-sql / --from-download / --from-flutterapp-pg 只能选一种",
            file=sys.stderr,
        )
        return None, None, 2

    dump_to_path: Path | None = None
    if args.dump_to:
        if src_n > 0:
            print(
                "错误: --dump-to 不能与 --from-sql / --from-download / --from-flutterapp-pg 同时使用",
                file=sys.stderr,
            )
            return None, None, 2
        dump_to_path = Path(args.dump_to).expanduser().resolve()

    sql_import_path: Path | None = None
    if args.from_download:
        raw = (os.environ.get("HZTECH_LOCAL_PG_SQL") or "").strip()
        sql_import_path = (
            Path(raw).expanduser().resolve()
            if raw
            else (project_root / "download" / "pg.sql").resolve()
        )
    elif args.from_flutterapp_pg:
        sql_import_path = (project_root / "flutterapp" / "pg").resolve()
    elif args.from_sql:
        sql_import_path = Path(args.from_sql).expanduser().resolve()

    return dump_to_path, sql_import_path, None


def _print_header(
    *,
    dump_to_path: Path | None,
    sql_import_path: Path | None,
    local_url: str,
    dump_schemas: list[str],
    exclude_schemas: list[str],
    cfg: dict,
    remote: RemotePgConn,
    rdb: str,
) -> None:
    print("=== 本地 PostgreSQL → AWS（经 SSH psql）===")
    if dump_to_path is not None:
        print("  本机导出（--clean --if-exists）→", dump_to_path)
        if dump_schemas:
            print("  本机 pg_dump 仅 schema:", ", ".join(dump_schemas))
        if exclude_schemas:
            print("  本机 pg_dump 排除 schema:", ", ".join(exclude_schemas))
    elif sql_import_path is not None:
        print("  导入 SQL 文件:", sql_import_path)
    else:
        print("  本地（源 live dump，已含 --clean --if-exists）:", mask_url(local_url))
        if dump_schemas:
            print("  本机 pg_dump 仅 schema:", ", ".join(dump_schemas))
        if exclude_schemas:
            print("  本机 pg_dump 排除 schema:", ", ".join(exclude_schemas))
    print(
        "  SSH:",
        (os.environ.get("HZTECH_SSH_PG_TARGET") or "").strip()
        or f'{cfg["ssh_user"]}@{cfg["ssh_host"]}',
        "端口",
        cfg["ssh_port"],
    )
    print("  远端 psql:", f"{remote.user}@{remote.host}:{remote.port}/{rdb}")
    print("---")


def _dry_run_print(
    *,
    dump_to_path: Path | None,
    sql_import_path: Path | None,
    dump_cmd: list[str],
    local_url: str,
    full_ssh: list[str],
    no_ensure_remote_db: bool,
    backup_remote_first: bool,
    project_root: Path,
) -> None:
    if dump_to_path is not None:
        dump_display = dump_cmd[:-1] + [mask_url(local_url)]
        print("[dry-run]", shlex.join(dump_display), ">", str(dump_to_path))
        print("[dry-run] cat", dump_to_path, "|", dry_run_ssh_line(full_ssh))
    elif sql_import_path is not None:
        print("[dry-run] cat", sql_import_path, "| ssh ... psql ...")
    else:
        dump_display = dump_cmd[:-1] + [mask_url(local_url)]
        print("[dry-run]", shlex.join(dump_display), "|", dry_run_ssh_line(full_ssh))
    if not no_ensure_remote_db:
        print(
            "[dry-run] ssh … bash: sudo -u postgres 确保角色/库/schema（无库则创建，同 install_postgresql_remote）"
        )
    if backup_remote_first:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        snap = project_root / ".temp-cursor" / f"aws_before_import_{ts}.sql"
        print("[dry-run] 远端 pg_dump →", snap)


def build_arg_parser(default_remote_db: str = "hztech") -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="本地 PostgreSQL dump 经 SSH 导入 AWS（默认仅应用 schema，与 database_config/postgres_schema 或 flutterapp 一致；整库用 --dump-full 或 HZTECH_PG_DUMP_FULL=1；远端库默认 hztech）",
    )
    ap.add_argument(
        "--role",
        default="baasapi",
        choices=("baasapi", "flutterapp"),
        help="deploy-aws.json 段（PostgreSQL 在 baasapi 机）",
    )
    ap.add_argument(
        "--remote-db",
        default="",
        help=f"远端数据库名（默认: 环境变量 HZTECH_REMOTE_PG_DB 或 {default_remote_db}）",
    )
    ap.add_argument("--dry-run", action="store_true", help="只打印将执行的命令，不导入")
    ap.add_argument(
        "--no-ensure-remote-db",
        action="store_true",
        help="跳过远端 sudo postgres 建库/角色/schema（目标库必须已存在）",
    )
    ap.add_argument(
        "--backup-remote-first",
        action="store_true",
        help="导入前将远端当前库 dump 到 .temp-cursor/",
    )
    ap.add_argument(
        "--from-sql",
        metavar="PATH",
        help="不从本机 live 库 dump，改为读取已有 plain SQL 文件导入远端",
    )
    ap.add_argument(
        "--from-download",
        action="store_true",
        help="从项目根下 download/pg.sql 导入（可用环境变量 HZTECH_LOCAL_PG_SQL 指定其它路径）",
    )
    ap.add_argument(
        "--from-flutterapp-pg",
        action="store_true",
        help="从项目根下 flutterapp/pg 导入（仓库内 pg_dump 文本）",
    )
    ap.add_argument(
        "--strip-pg18-restrict",
        action="store_true",
        help="跳过首行 \\\\restrict（pg_dump 18；远端 psql 较旧时可避免报错）",
    )
    ap.add_argument(
        "--dump-to",
        metavar="PATH",
        help="本机 pg_dump（--clean --if-exists）写入该文件后再导入远端；不可与 --from-sql 等共用",
    )
    ap.add_argument(
        "--dump-schema",
        action="append",
        dest="dump_schemas",
        metavar="NAME",
        help="本机 pg_dump --schema=NAME（可重复）；指定后仅导出列出的 schema",
    )
    ap.add_argument(
        "--exclude-dump-schema",
        action="append",
        dest="exclude_dump_schemas",
        metavar="NAME",
        help="本机 pg_dump --exclude-schema=NAME（可重复）；排除无 USAGE 权限的 schema（如 QTrader）",
    )
    ap.add_argument(
        "--dump-app-schema-only",
        action="store_true",
        help="本机 pg_dump 仅导出单个应用 schema：HZTECH_APP_PG_SCHEMA，否则 HZTECH_POSTGRES_SCHEMA / database_config postgres_schema，默认 flutterapp"
        "（与 ops/pg_dump_to_aws_alpha.sh 的 HZTECH_PG_DUMP_APP_ONLY 一致）。"
        "导入目标库仍为 HZTECH_REMOTE_PG_DB（默认 hztech）。",
    )
    ap.add_argument(
        "--dump-full",
        action="store_true",
        dest="dump_full",
        help="本机 pg_dump 导出整库（仍会默认排除 QTrader，除非 HZTECH_PG_DUMP_INCLUDE_QTRADER=1）。"
        "与无参默认的「仅应用 schema」相对；也可设环境变量 HZTECH_PG_DUMP_FULL=1。",
    )
    return ap


def main(argv: list[str] | None = None) -> int:
    default_remote_db = "hztech"
    ap = build_arg_parser(default_remote_db)
    args = ap.parse_args(argv)

    _apply_default_dump_scope(args)
    if args.dump_full and args.dump_app_schema_only:
        print(
            "错误: --dump-full 与 --dump-app-schema-only 不能同时使用",
            file=sys.stderr,
        )
        return 2
    if args.dump_full and (
        args.dump_schemas or schemas_from_env("HZTECH_PG_DUMP_SCHEMAS")
    ):
        print(
            "错误: --dump-full 不能与 --dump-schema / HZTECH_PG_DUMP_SCHEMAS 同时使用",
            file=sys.stderr,
        )
        return 2

    lists = _resolve_dump_lists(args)
    if isinstance(lists, int):
        return lists
    dump_schema_list, exclude_dump_schema_list = lists

    dump_to_path, sql_import_path, path_err = _resolve_sql_paths(
        args, project_root=PROJECT_ROOT
    )
    if path_err is not None:
        return path_err

    if args.role != "baasapi":
        print(
            "提示: PostgreSQL 通常在 baasapi 机上。",
            file=sys.stderr,
        )

    remote_db = (args.remote_db or "").strip()
    if not remote_db:
        remote_db = (os.environ.get("HZTECH_REMOTE_PG_DB") or "").strip()
    if not remote_db:
        remote_db = default_remote_db

    local_url = resolve_local_database_url()
    remote = RemotePgConn.from_env()
    rdb = remote_db

    try:
        cfg = load_deploy_json(args.role)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as e:
        print("读取部署配置失败:", e, file=sys.stderr)
        return 1

    ssh_base = ssh_argv(cfg)

    _print_header(
        dump_to_path=dump_to_path,
        sql_import_path=sql_import_path,
        local_url=local_url,
        dump_schemas=dump_schema_list,
        exclude_schemas=exclude_dump_schema_list,
        cfg=cfg,
        remote=remote,
        rdb=rdb,
    )

    need_pg_dump = dump_to_path is not None or sql_import_path is None
    if not which("pg_dump") and need_pg_dump:
        print(
            "错误: 未找到 pg_dump，请安装 PostgreSQL 客户端（如 brew install libpq）。",
            file=sys.stderr,
        )
        return 1

    dump_cmd = pg_dump_args(
        local_url,
        dump_schemas=dump_schema_list if dump_schema_list else None,
        exclude_schemas=exclude_dump_schema_list if exclude_dump_schema_list else None,
    )
    psql_remote = remote_psql_argv(
        remote.host, remote.port, rdb, remote.user, remote.password
    )
    full_ssh = ssh_base + psql_remote

    if args.dry_run:
        _dry_run_print(
            dump_to_path=dump_to_path,
            sql_import_path=sql_import_path,
            dump_cmd=dump_cmd,
            local_url=local_url,
            full_ssh=full_ssh,
            no_ensure_remote_db=args.no_ensure_remote_db,
            backup_remote_first=args.backup_remote_first,
            project_root=PROJECT_ROOT,
        )
        return 0

    PROJECT_ROOT.joinpath(".temp-cursor").mkdir(parents=True, exist_ok=True)

    if not args.no_ensure_remote_db:
        print(
            "=== 确保远端角色/数据库/schema（无主库时创建，同 install_postgresql_remote）===",
        )
        try:
            pg_schema = (
                app_dump_pg_schema()
                if args.dump_app_schema_only
                else remote_postgres_schema()
            )
            ere = run_ensure_remote_database(
                ssh_base,
                pg_db=rdb,
                pg_user=remote.user,
                pg_password=remote.password,
                pg_schema=pg_schema,
                cwd=str(PROJECT_ROOT),
            )
        except ValueError as e:
            print("错误:", e, file=sys.stderr)
            return 2
        if ere != 0:
            print(f"远端建库准备失败，退出码 {ere}", file=sys.stderr)
            return ere

    if args.backup_remote_first:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        snap = PROJECT_ROOT / ".temp-cursor" / f"aws_before_import_{ts}.sql"
        print("=== 先备份远端当前库到:", snap, "===")
        rc = run_backup_remote(
            ssh_base,
            remote.host,
            remote.port,
            rdb,
            remote.user,
            remote.password,
            snap,
            cwd=str(PROJECT_ROOT),
            dump_schemas=dump_schema_list if dump_schema_list else None,
            exclude_schemas=exclude_dump_schema_list
            if exclude_dump_schema_list
            else None,
        )
        if rc != 0:
            print(f"远端备份失败，退出码 {rc}", file=sys.stderr)
            return rc
        print("  已写入", snap)

    print("=== 开始导入（ON_ERROR_STOP）===")

    file_to_import: Path | None = sql_import_path
    if dump_to_path is not None:
        print("=== 本机 pg_dump（--clean --if-exists）→", dump_to_path, "===")
        dump_to_path.parent.mkdir(parents=True, exist_ok=True)
        with dump_to_path.open("wb") as wf:
            dr = subprocess.run(
                dump_cmd,
                stdout=wf,
                stderr=subprocess.PIPE,
                cwd=str(PROJECT_ROOT),
                check=False,
            )
        if dr.stderr:
            sys.stderr.write(dr.stderr.decode("utf-8", errors="replace"))
        if dr.returncode != 0:
            print(
                f"错误: 本机 pg_dump 失败（退出码 {dr.returncode}）",
                file=sys.stderr,
            )
            return dr.returncode
        file_to_import = dump_to_path

    if file_to_import is not None:
        if not file_to_import.is_file():
            print("错误: 找不到文件", file_to_import, file=sys.stderr)
            return 1
        r = run_psql_with_sql_file(
            full_ssh,
            file_to_import,
            strip_pg18_restrict=args.strip_pg18_restrict,
            cwd=str(PROJECT_ROOT),
        )
    else:
        r, pipe_rc = run_dump_pipe_to_remote_psql(
            dump_cmd,
            full_ssh,
            str(PROJECT_ROOT),
        )
        if pipe_rc != 0:
            return pipe_rc

    if r.stderr:
        sys.stderr.write(r.stderr.decode("utf-8", errors="replace"))
    if r.stdout:
        sys.stdout.write(r.stdout.decode("utf-8", errors="replace"))
    if r.returncode != 0:
        print(f"错误: 远端 psql 导入失败（退出码 {r.returncode}）", file=sys.stderr)
        return r.returncode

    print("=== 完成：数据已导入远端库", rdb, "===")
    print(
        "验证可执行: HZTECH_REMOTE_PG_DB=%s ./ops/pg_ops.sh test-aws" % rdb,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
