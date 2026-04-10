#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地 PostgreSQL → AWS BaasAPI 机（经 SSH 在远端执行 psql）全库导入。

与 ops/pg_dump_to_aws_alpha.sh 等价流程：本机 pg_dump（plain SQL）管道到远端 psql。
差别：默认目标库名为 hztechapp（可用环境变量或参数覆盖为 hztech 等）。

本地连接（与 ops/test_local_postgres.py 一致）：
  1. 环境变量 DATABASE_URL
  2. baasapi/database_config.json（若存在）
  3. baasapi/database_config.example.json（若存在）
  4. postgresql://hztech:Alpha@127.0.0.1:5432/hztech

远端（与 install_postgresql_remote / test_aws_postgres 一致）：
  HZTECH_REMOTE_PG_HOST（默认 127.0.0.1）、HZTECH_REMOTE_PG_PORT（5432）、
  HZTECH_REMOTE_PG_USER（hztech）、HZTECH_REMOTE_PG_DB（本脚本默认 hztechapp）、
  HZTECH_REMOTE_PG_PASSWORD 或 POSTGRES_PASSWORD

SSH：read_deploy_config.py --role baasapi；HZTECH_SSH_PG_TARGET、HZTECH_SSH_KEY_FILE、
  HZTECH_SSH_OPTS 可覆盖。

导入前默认在远端用 postgres 超级用户建库/角色/schema（与 baasapi/install_postgresql_remote.sh
  同源逻辑）；远端尚无数据库时会自动创建。跳过：--no-ensure-remote-db

用法：
  python3 ops/migrate_local_pg_to_aws.py
  python3 ops/migrate_local_pg_to_aws.py --dry-run
  python3 ops/migrate_local_pg_to_aws.py --backup-remote-first
  python3 ops/migrate_local_pg_to_aws.py --from-download
    （项目根/download/pg.sql → 远端 hztechapp；路径可用 HZTECH_LOCAL_PG_SQL 覆盖）
  python3 ops/migrate_local_pg_to_aws.py --from-flutterapp-pg
    （项目根/flutterapp/pg → 远端 hztechapp；与 Flutter 仓库内 pg_dump 备份一致）
  python3 ops/migrate_local_pg_to_aws.py --from-flutterapp-pg --strip-pg18-restrict
    （远端 psql 较旧不认识 \\restrict 时使用）
  python3 ops/migrate_local_pg_to_aws.py --from-sql /path/to/dump.sql
  python3 ops/migrate_local_pg_to_aws.py --dump-to .temp-cursor/local_hztech_clean.sql
    （本机 pg_dump 已含 --clean --if-exists，先写入该文件再导入远端 hztechapp）
  python3 ops/migrate_local_pg_to_aws.py --dump-to .temp-cursor/local.sql --exclude-dump-schema QTrader
    （本机用户无权读某 schema 时排除之；或设 HZTECH_PG_DUMP_EXCLUDE_SCHEMAS=QTrader）
  python3 ops/migrate_local_pg_to_aws.py --dump-schema flutterapp --dump-schema public
    （只导出指定 schema）
  python3 ops/migrate_local_pg_to_aws.py --dump-app-schema-only --dump-to .temp-cursor/app.sql
    （仅导出 HZTECH_POSTGRES_SCHEMA，默认 flutterapp；AWS 目标库名仍为 hztechapp）
  python3 ops/migrate_local_pg_to_aws.py --remote-db hztech
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from shutil import which

OPS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = OPS_DIR.parent
BAASAPI_DIR = PROJECT_ROOT / "baasapi"


def _resolve_local_database_url() -> str:
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


def _validate_pg_ident(name: str) -> None:
    if not name:
        raise ValueError("空的数据库标识符")
    if not (name[0].isalpha() or name[0] == "_"):
        raise ValueError(f"非法的数据库标识符: {name!r}")
    for ch in name:
        if not (ch.isalnum() or ch == "_"):
            raise ValueError(f"非法的数据库标识符: {name!r}")


def _remote_postgres_schema() -> str:
    s = (os.environ.get("HZTECH_POSTGRES_SCHEMA") or "flutterapp").strip()
    return s or "flutterapp"


def _schemas_from_env(var: str) -> list[str]:
    raw = (os.environ.get(var) or "").strip()
    if not raw:
        return []
    return [x.strip() for x in raw.split(",") if x.strip()]


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


def _remote_pg_credentials() -> tuple[str, int, str, str]:
    """远端主机、端口、数据库用户、密码（库名由调用方解析）。"""
    host = (os.environ.get("HZTECH_REMOTE_PG_HOST") or "127.0.0.1").strip()
    port = int((os.environ.get("HZTECH_REMOTE_PG_PORT") or "5432").strip())
    user = (os.environ.get("HZTECH_REMOTE_PG_USER") or "hztech").strip()
    pw = (
        os.environ.get("HZTECH_REMOTE_PG_PASSWORD")
        or os.environ.get("POSTGRES_PASSWORD")
        or "Alpha"
    )
    return host, port, user, pw


def _ssh_argv(cfg: dict) -> list[str]:
    ssh_argv: list[str] = ["ssh"]
    for o in cfg.get("ssh_opts") or []:
        ssh_argv.append(str(o))
    extra = (os.environ.get("HZTECH_SSH_OPTS") or "").strip()
    if extra:
        ssh_argv.extend(shlex.split(extra))
    key = (os.environ.get("HZTECH_SSH_KEY_FILE") or "").strip() or cfg["ssh_key"]
    target = (os.environ.get("HZTECH_SSH_PG_TARGET") or "").strip() or (
        f'{cfg["ssh_user"]}@{cfg["ssh_host"]}'
    )
    ssh_argv.extend(
        [
            "-i",
            key,
            "-p",
            str(int(cfg["ssh_port"])),
            target,
        ]
    )
    return ssh_argv


def _pg_dump_args(
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
            _validate_pg_ident(s)
            cmd.append(f"--schema={s}")
    if exclude_schemas:
        for s in exclude_schemas:
            _validate_pg_ident(s)
            cmd.append(f"--exclude-schema={s}")
    cmd.append(local_url)
    return cmd


def _dry_run_ssh_line(full_ssh: list[str]) -> str:
    masked = list(full_ssh)
    for i, part in enumerate(masked):
        if part.startswith("PGPASSWORD="):
            masked[i] = "PGPASSWORD=***"
            break
    return shlex.join(masked)


def _remote_psql_argv(
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


def _run_backup_remote(
    ssh_argv: list[str],
    rh: str,
    rp: int,
    rdb: str,
    ru: str,
    rpw: str,
    out_path: Path,
) -> int:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    remote = (
        "set -euo pipefail\n"
        "command -v pg_dump >/dev/null 2>&1 || "
        '{ echo "远端未安装 pg_dump，请去掉 --backup-remote-first" >&2; exit 1; }\n'
        f"export PGPASSWORD={shlex.quote(rpw)}\n"
        f"pg_dump --format=p --no-owner --no-acl "
        f"-h {shlex.quote(rh)} -p {rp} -U {shlex.quote(ru)} -d {shlex.quote(rdb)}\n"
    )
    with out_path.open("wb") as wf:
        r = subprocess.run(
            ssh_argv + ["bash", "-s"],
            input=remote.encode("utf-8"),
            stdout=wf,
            stderr=subprocess.PIPE,
            cwd=str(PROJECT_ROOT),
            check=False,
        )
    if r.stderr:
        sys.stderr.write(r.stderr.decode("utf-8", errors="replace"))
    return r.returncode


def _run_ensure_remote_database(
    ssh_base: list[str],
    *,
    pg_db: str,
    pg_user: str,
    pg_password: str,
    pg_schema: str,
    cwd: str,
) -> int:
    """经 SSH 在远端以 sudo -u postgres 建角色/库/schema（与 install_postgresql_remote 一致）。"""
    _validate_pg_ident(pg_db)
    _validate_pg_ident(pg_user)
    _validate_pg_ident(pg_schema)
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


def _run_psql_with_sql_file(
    full_ssh: list[str],
    sql_path: Path,
    *,
    strip_pg18_restrict: bool,
    cwd: str,
) -> subprocess.CompletedProcess:
    """将本地 plain SQL 经 stdin 送入 SSH 上的 psql。

    始终跳过 pg_dump 18 的 \\\\restrict / \\\\unrestrict（远端旧 psql 会报错）；
    跳过 SET transaction_timeout（PG17+ 特有，PG15 无此参数）。
    strip_pg18_restrict 仍保留作兼容，行为与上述一致。
    """
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


def main() -> int:
    default_remote_db = "hztechapp"
    ap = argparse.ArgumentParser(
        description="本地 PostgreSQL 全量 dump 经 SSH 导入 AWS 上指定库（默认 hztechapp）",
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
        help="本机 pg_dump 仅导出 HZTECH_POSTGRES_SCHEMA（默认 flutterapp，与 baasapi 一致）。"
        "AWS 上库名常为 hztechapp，勿与 schema 名混淆。",
    )
    args = ap.parse_args()

    if args.dump_app_schema_only:
        if args.dump_schemas:
            print(
                "错误: --dump-app-schema-only 不能与 --dump-schema 同时使用",
                file=sys.stderr,
            )
            return 2
        if _schemas_from_env("HZTECH_PG_DUMP_SCHEMAS"):
            print(
                "错误: --dump-app-schema-only 与 HZTECH_PG_DUMP_SCHEMAS 冲突",
                file=sys.stderr,
            )
            return 2
        if args.exclude_dump_schemas or _schemas_from_env(
            "HZTECH_PG_DUMP_EXCLUDE_SCHEMAS"
        ):
            print(
                "错误: --dump-app-schema-only 已限定单 schema，"
                "请去掉 --exclude-dump-schema / HZTECH_PG_DUMP_EXCLUDE_SCHEMAS",
                file=sys.stderr,
            )
            return 2
        try:
            app_sch = _remote_postgres_schema()
            _validate_pg_ident(app_sch)
        except ValueError as e:
            print("错误:", e, file=sys.stderr)
            return 2
        _dump_schema_list = [app_sch]
        _exclude_dump_schema_list: list[str] = []
    else:
        _dump_schema_list = list(args.dump_schemas or [])
        _dump_schema_list.extend(_schemas_from_env("HZTECH_PG_DUMP_SCHEMAS"))
        _exclude_dump_schema_list = list(args.exclude_dump_schemas or [])
        _exclude_dump_schema_list.extend(
            _schemas_from_env("HZTECH_PG_DUMP_EXCLUDE_SCHEMAS")
        )
    try:
        for s in _dump_schema_list:
            _validate_pg_ident(s)
        for s in _exclude_dump_schema_list:
            _validate_pg_ident(s)
    except ValueError as e:
        print("错误（--dump-schema / --exclude-dump-schema）:", e, file=sys.stderr)
        return 2

    _src_n = (
        int(bool(args.from_sql))
        + int(args.from_download)
        + int(args.from_flutterapp_pg)
    )
    if _src_n > 1:
        print(
            "错误: --from-sql / --from-download / --from-flutterapp-pg 只能选一种",
            file=sys.stderr,
        )
        return 2

    dump_to_path: Path | None = None
    if args.dump_to:
        if _src_n > 0:
            print(
                "错误: --dump-to 不能与 --from-sql / --from-download / --from-flutterapp-pg 同时使用",
                file=sys.stderr,
            )
            return 2
        dump_to_path = Path(args.dump_to).expanduser().resolve()

    sql_import_path: Path | None = None
    if args.from_download:
        raw = (os.environ.get("HZTECH_LOCAL_PG_SQL") or "").strip()
        sql_import_path = (
            Path(raw).expanduser().resolve()
            if raw
            else (PROJECT_ROOT / "download" / "pg.sql").resolve()
        )
    elif args.from_flutterapp_pg:
        sql_import_path = (PROJECT_ROOT / "flutterapp" / "pg").resolve()
    elif args.from_sql:
        sql_import_path = Path(args.from_sql).expanduser().resolve()

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

    local_url = _resolve_local_database_url()
    rh, rp, ru, rpw = _remote_pg_credentials()
    rdb = remote_db

    try:
        cfg = _load_deploy_json(args.role)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as e:
        print("读取部署配置失败:", e, file=sys.stderr)
        return 1

    ssh_base = _ssh_argv(cfg)

    print("=== 本地 PostgreSQL → AWS（经 SSH psql）===")
    if dump_to_path is not None:
        print("  本机导出（--clean --if-exists）→", dump_to_path)
        if _dump_schema_list:
            print("  本机 pg_dump 仅 schema:", ", ".join(_dump_schema_list))
        if _exclude_dump_schema_list:
            print("  本机 pg_dump 排除 schema:", ", ".join(_exclude_dump_schema_list))
    elif sql_import_path is not None:
        print("  导入 SQL 文件:", sql_import_path)
    else:
        print("  本地（源 live dump，已含 --clean --if-exists）:", _mask_url(local_url))
        if _dump_schema_list:
            print("  本机 pg_dump 仅 schema:", ", ".join(_dump_schema_list))
        if _exclude_dump_schema_list:
            print("  本机 pg_dump 排除 schema:", ", ".join(_exclude_dump_schema_list))
    print(
        "  SSH:",
        (os.environ.get("HZTECH_SSH_PG_TARGET") or "").strip()
        or f'{cfg["ssh_user"]}@{cfg["ssh_host"]}',
        "端口",
        cfg["ssh_port"],
    )
    print("  远端 psql:", f"{ru}@{rh}:{rp}/{rdb}")
    print("---")

    _need_pg_dump = dump_to_path is not None or sql_import_path is None
    if not which("pg_dump") and _need_pg_dump:
        print(
            "错误: 未找到 pg_dump，请安装 PostgreSQL 客户端（如 brew install libpq）。",
            file=sys.stderr,
        )
        return 1

    dump_cmd = _pg_dump_args(
        local_url,
        dump_schemas=_dump_schema_list if _dump_schema_list else None,
        exclude_schemas=_exclude_dump_schema_list if _exclude_dump_schema_list else None,
    )
    psql_remote = _remote_psql_argv(rh, rp, rdb, ru, rpw)
    full_ssh = ssh_base + psql_remote

    if args.dry_run:
        if dump_to_path is not None:
            dump_display = dump_cmd[:-1] + [_mask_url(local_url)]
            print("[dry-run]", shlex.join(dump_display), ">", str(dump_to_path))
            print("[dry-run] cat", dump_to_path, "|", _dry_run_ssh_line(full_ssh))
        elif sql_import_path is not None:
            print("[dry-run] cat", sql_import_path, "| ssh ... psql ...")
        else:
            dump_display = dump_cmd[:-1] + [_mask_url(local_url)]
            print("[dry-run]", shlex.join(dump_display), "|", _dry_run_ssh_line(full_ssh))
        if not args.no_ensure_remote_db:
            print(
                "[dry-run] ssh … bash: sudo -u postgres 确保角色/库/schema（无库则创建，同 install_postgresql_remote）"
            )
        if args.backup_remote_first:
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            snap = PROJECT_ROOT / ".temp-cursor" / f"aws_before_import_{ts}.sql"
            print("[dry-run] 远端 pg_dump →", snap)
        return 0

    PROJECT_ROOT.joinpath(".temp-cursor").mkdir(parents=True, exist_ok=True)

    if not args.no_ensure_remote_db:
        print(
            "=== 确保远端角色/数据库/schema（无主库时创建，同 install_postgresql_remote）===",
        )
        try:
            pg_schema = _remote_postgres_schema()
            ere = _run_ensure_remote_database(
                ssh_base,
                pg_db=rdb,
                pg_user=ru,
                pg_password=rpw,
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
        rc = _run_backup_remote(ssh_base, rh, rp, rdb, ru, rpw, snap)
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
        r = _run_psql_with_sql_file(
            full_ssh,
            file_to_import,
            strip_pg18_restrict=args.strip_pg18_restrict,
            cwd=str(PROJECT_ROOT),
        )
    else:
        dump_p = subprocess.Popen(
            dump_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(PROJECT_ROOT),
        )
        assert dump_p.stdout is not None
        r = subprocess.run(
            full_ssh,
            stdin=dump_p.stdout,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(PROJECT_ROOT),
            check=False,
        )
        dump_p.stdout.close()
        dump_err = dump_p.stderr.read() if dump_p.stderr else b""
        dump_rc = dump_p.wait()
        if dump_rc != 0:
            if dump_err:
                sys.stderr.write(dump_err.decode("utf-8", errors="replace"))
            print(f"错误: 本机 pg_dump 失败（退出码 {dump_rc}）", file=sys.stderr)
            return dump_rc
        if dump_err:
            sys.stderr.write(dump_err.decode("utf-8", errors="replace"))

    if r.stderr:
        sys.stderr.write(r.stderr.decode("utf-8", errors="replace"))
    if r.stdout:
        sys.stdout.write(r.stdout.decode("utf-8", errors="replace"))
    if r.returncode != 0:
        print(f"错误: 远端 psql 导入失败（退出码 {r.returncode}）", file=sys.stderr)
        return r.returncode

    print("=== 完成：数据已导入远端库", rdb, "===")
    print("验证可执行: HZTECH_REMOTE_PG_DB=%s python3 ops/test_aws_postgres.py" % rdb)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
