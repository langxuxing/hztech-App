#!/usr/bin/env python3
"""统一部署编排：AWS 与本地。由 deploy2AWS.sh / deploy2Local.sh 薄封装调用。

详见仓库内部署规划文档；python3 baasapi/deploy_orchestrator.py --help
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def _log(msg: str) -> None:
    print("[deploy] %s" % msg)


def _resolve_config_path(raw: str) -> Path:
    p = Path(raw)
    return p.resolve() if p.is_absolute() else (PROJECT_ROOT / p).resolve()


def _load_server_mgr():
    """动态加载 server_mgr（避免包名依赖）。"""
    path = PROJECT_ROOT / "baasapi" / "server_mgr.py"
    spec = importlib.util.spec_from_file_location("hztech_server_mgr", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("无法加载 server_mgr")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _run_sm(args: list[str], dry_run: bool) -> int:
    cmd = [sys.executable, str(PROJECT_ROOT / "baasapi" / "server_mgr.py")] + args
    if dry_run:
        _log("dry-run: %s" % cmd)
        return 0
    r = subprocess.run(cmd, cwd=str(PROJECT_ROOT))
    return int(r.returncode or 0)


def _run_flutter_clean(dry_run: bool) -> int:
    cmd = ["flutter", "clean"]
    if dry_run:
        _log("dry-run: %s (cwd=flutterapp)" % cmd)
        return 0
    r = subprocess.run(cmd, cwd=str(PROJECT_ROOT / "flutterapp"))
    return int(r.returncode or 0)


def _http_ok(url: str, label: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    except OSError:
        code = 0
    ok = code in (200, 503)
    print("  %s %s -> HTTP %s (%s)" % ("OK" if ok else "WARN", label, code, url))
    return ok


def _verify_local_urls() -> int:
    api = int(os.environ.get("HZTECH_LOCAL_API_PORT") or os.environ.get("PORT") or "9001")
    web = int(os.environ.get("HZTECH_LOCAL_WEB_PORT") or "9000")
    ok = _http_ok("http://127.0.0.1:%s/api/health" % api, "BaasAPI health")
    ok = _http_ok("http://127.0.0.1:%s/" % web, "FlutterApp /") and ok
    return 0 if ok else 1


def _run_local_init_db(dry_run: bool) -> int:
    if dry_run:
        _log("dry-run: init_db()")
        return 0
    env = os.environ.copy()
    env["PYTHONPATH"] = str(PROJECT_ROOT)
    r = subprocess.run(
        [
            sys.executable,
            "-c",
            "from baasapi.db import init_db; init_db()",
        ],
        cwd=str(PROJECT_ROOT),
        env=env,
    )
    return int(r.returncode or 0)


def _parse_build_set(s: str) -> set[str]:
    return {x.strip().lower() for x in s.split(",") if x.strip()}


def _ios_build_allowed() -> bool:
    v = os.environ.get("HZTECH_SKIP_IOS_BUILD", "1").strip().lower()
    return v in ("0", "false", "no")


def _env_truthy(name: str) -> bool:
    v = os.environ.get(name, "").strip().lower()
    return v in ("1", "true", "yes")


def _should_run_db_migrate(cli_db: bool) -> bool:
    if cli_db:
        return True
    if os.environ.get("HZTECH_SKIP_DB_SYNC", "").strip() == "0":
        return True
    sk = os.environ.get("HZTECH_SKIP_DB_SYNC", "").strip().lower()
    if sk in ("1", "true", "yes"):
        return False
    return _env_truthy("HZTECH_DB_SYNC")


def _apply_local_defaults() -> None:
    port_fb = os.environ.get("PORT", "9001")
    api = os.environ.get("HZTECH_LOCAL_API_PORT") or port_fb
    os.environ.setdefault("HZTECH_LOCAL_API_PORT", api)
    os.environ.setdefault("HZTECH_LOCAL_WEB_PORT", "9000")
    os.environ.setdefault("HZTECH_LOCAL_WEB_STATIC", "1")
    os.environ.setdefault("HZTECH_DB_BACKEND", "postgresql")
    sqlite_tmpl = PROJECT_ROOT / "baasapi" / "database_config.local.sqlite.json"
    if os.environ.get("HZTECH_DB_BACKEND") == "sqlite" and not os.environ.get(
        "HZTECH_DB_CONFIG"
    ):
        if sqlite_tmpl.is_file():
            os.environ["HZTECH_DB_CONFIG"] = str(sqlite_tmpl)
    os.environ.setdefault("HZTECH_API_BASE_URL", "http://192.168.3.41:9001/")
    os.environ.setdefault(
        "FLUTTER_DART_DEFINE_FILE", "flutterapp/dart_defines/local.json"
    )
    os.environ.setdefault("HZTECH_SKIP_IOS_BUILD", "1")
    os.environ.setdefault("HZTECH_APP_ANDROID_APK", "hztech-app-debug.apk")


def _apply_aws_defaults() -> None:
    os.environ.setdefault("HZTECH_SKIP_IOS_BUILD", "1")
    os.environ.setdefault("HZTECH_DB_BACKEND", "postgresql")
    os.environ.setdefault(
        "FLUTTER_DART_DEFINE_FILE", "flutterapp/dart_defines/production.json"
    )


def run_aws(ns: argparse.Namespace) -> int:
    cfg_path = _resolve_config_path(ns.config)
    if not cfg_path.is_file():
        print("错误: 未找到部署配置: %s" % cfg_path, file=sys.stderr)
        return 1
    os.environ["DEPLOY_CONFIG"] = str(cfg_path)
    _apply_aws_defaults()
    if ns.dart_define_file:
        os.environ["FLUTTER_DART_DEFINE_FILE"] = ns.dart_define_file
    if ns.db_backend:
        os.environ["HZTECH_DB_BACKEND"] = ns.db_backend
    if "HZTECH_API_BASE_URL" not in os.environ:
        sm = _load_server_mgr()
        os.environ["HZTECH_API_BASE_URL"] = sm.default_hztech_api_base_url()

    skip_build = ns.skip_build or os.environ.get("HZTECH_SKIP_BUILD", "").strip() == "1"
    bset = _parse_build_set(ns.build)
    if skip_build:
        bset = set()

    if ns.db_reset:
        if os.environ.get("HZTECH_ALLOW_DB_RESET") != "1":
            print(
                "错误: --db-reset 需同时设置环境变量 HZTECH_ALLOW_DB_RESET=1",
                file=sys.stderr,
            )
            return 2
        print("错误: 数据库破坏性重建尚未实现，请使用 init_db/db-sync 迁移。", file=sys.stderr)
        return 3

    print("==============================================")
    print("  Ops 部署（orchestrator）AWS")
    print("  配置: %s" % cfg_path)
    print("  构建目标: %s  skip_build=%s" % (",".join(sorted(bset)) or "(无)", skip_build))
    print("  API_BASE_URL: %s" % os.environ.get("HZTECH_API_BASE_URL", ""))
    print("==============================================")

    if ns.flutter_clean:
        rc = _run_flutter_clean(ns.dry_run)
        if rc != 0:
            return rc

    if not skip_build:
        if "android" in bset:
            if ns.flutter_mode == "release":
                rc = _run_sm(["build"], ns.dry_run)
            else:
                rc = _run_sm(["build-debug"], ns.dry_run)
            if rc != 0:
                return rc
        if "ios" in bset:
            if not _ios_build_allowed():
                _log("跳过 iOS（HZTECH_SKIP_IOS_BUILD 未设为 0/false/no）")
            else:
                rc = _run_sm(["build-ios"], ns.dry_run)
                if rc != 0:
                    return rc
        if "web" in bset:
            if ns.flutter_mode == "debug":
                _log("提示: Web 暂仅 release 构建，忽略 --flutter-mode debug")
            rc = _run_sm(["build-web"], ns.dry_run)
            if rc != 0:
                _log("Web 构建失败（继续同步，远端 Web 可能 503）")

    deploy_args = ["deploy", "--no-start"]
    if ns.rsync_no_delete:
        deploy_args.append("--rsync-no-delete")
    rc = _run_sm(deploy_args, ns.dry_run)
    if rc != 0:
        return rc

    if _should_run_db_migrate(ns.db):
        rc = _run_sm(["db-sync"], ns.dry_run)
        if rc != 0:
            return rc

    if not ns.no_start:
        rc = _run_sm(["restart"], ns.dry_run)
        if rc != 0:
            return rc

    do_verify = ns.verify or _env_truthy("HZTECH_POST_DEPLOY_VERIFY")
    if do_verify:
        print("")
        print("=== 部署后探测 ===")
        rc = _run_sm(["verify"], ns.dry_run)
        if rc != 0:
            return rc

    _log(
        "摘要: target=aws config=%s sync_mirror=%s db_migrate=%s restart=%s verify=%s dry_run=%s"
        % (
            cfg_path.name,
            not ns.rsync_no_delete,
            _should_run_db_migrate(ns.db),
            not ns.no_start,
            do_verify,
            ns.dry_run,
        )
    )
    return 0


def run_local(ns: argparse.Namespace) -> int:
    _apply_local_defaults()
    if ns.db_backend:
        os.environ["HZTECH_DB_BACKEND"] = ns.db_backend
    if ns.dart_define_file:
        os.environ["FLUTTER_DART_DEFINE_FILE"] = ns.dart_define_file
    skip_pip = ns.skip_pip or os.environ.get(
        "HZTECH_SKIP_PIP_INSTALL", ""
    ).strip().lower() in ("1", "true", "yes")

    if ns.db_reset:
        if os.environ.get("HZTECH_ALLOW_DB_RESET") != "1":
            print(
                "错误: --db-reset 需同时设置环境变量 HZTECH_ALLOW_DB_RESET=1",
                file=sys.stderr,
            )
            return 2
        print("错误: 数据库破坏性重建尚未实现。", file=sys.stderr)
        return 3

    skip_build = ns.skip_build
    bset = _parse_build_set(ns.build)
    skip_mobile = getattr(ns, "skip_mobile_build", False) or os.environ.get(
        "HZTECH_SKIP_MOBILE_BUILD", ""
    ).strip().lower() in ("1", "true", "yes")
    skip_web = getattr(ns, "skip_web_build", False) or (
        os.environ.get("HZTECH_SKIP_WEB_BUILD", "").strip() == "1"
    )
    if skip_mobile:
        bset.discard("android")
        bset.discard("ios")
    if skip_web:
        bset.discard("web")
    if skip_build:
        bset = set()

    will_db = _should_run_db_migrate(ns.db)
    print("==============================================")
    print("  本地部署（orchestrator）")
    print(
        "  DB 后端=%s  初始化迁移(init_db)=%s"
        % (os.environ.get("HZTECH_DB_BACKEND", "postgresql"), "是" if will_db else "否（默认）")
    )
    print(
        "  构建: %s  flutter-mode=%s  (Web 产物仍为 release)"
        % (",".join(sorted(bset)) if bset else "(跳过)", ns.flutter_mode)
    )
    print(
        "  端口 API=%s Web静态=%s WEB_STATIC=%s"
        % (
            os.environ.get("HZTECH_LOCAL_API_PORT"),
            os.environ.get("HZTECH_LOCAL_WEB_PORT"),
            os.environ.get("HZTECH_LOCAL_WEB_STATIC"),
        )
    )
    print("==============================================")

    if not skip_pip:
        cmd = ["bash", str(PROJECT_ROOT / "baasapi" / "install_python_deps.sh")]
        if ns.dry_run:
            _log("dry-run: %s" % cmd)
        else:
            r = subprocess.run(cmd, cwd=str(PROJECT_ROOT))
            if r.returncode != 0:
                return int(r.returncode)

    if ns.flutter_clean:
        rc = _run_flutter_clean(ns.dry_run)
        if rc != 0:
            return rc

    if not skip_build:
        if "android" in bset:
            if ns.flutter_mode == "release":
                rc = _run_sm(["build"], ns.dry_run)
            else:
                rc = _run_sm(["build-debug"], ns.dry_run)
            if rc != 0:
                return rc
        if "ios" in bset:
            if not _ios_build_allowed():
                _log("跳过 iOS（HZTECH_SKIP_IOS_BUILD 未设为 0/false/no）")
            else:
                rc = _run_sm(["build-ios"], ns.dry_run)
                if rc != 0:
                    return rc
        if "web" in bset:
            if ns.flutter_mode == "debug":
                _log("提示: Web 暂仅 release 构建")
            rc = _run_sm(["build-web"], ns.dry_run)
            if rc != 0:
                _log("Web 构建失败")

    if _should_run_db_migrate(ns.db):
        rc = _run_local_init_db(ns.dry_run)
        if rc != 0:
            return rc

    do_verify = ns.verify or _env_truthy("HZTECH_POST_DEPLOY_VERIFY")
    if do_verify:
        print("")
        print("=== 本地探测 ===")
        rc = _verify_local_urls()
        if rc != 0:
            return rc

    if ns.no_start:
        _log(
            "摘要: target=local build=%s db_migrate=%s start=False verify=%s"
            % (
                ",".join(sorted(bset)) or "(skip)",
                _should_run_db_migrate(ns.db),
                do_verify,
            )
        )
        return 0

    _log("启动: baasapi/run_local.sh")
    if ns.dry_run:
        _log("dry-run: 未 exec run_local.sh")
        return 0

    rl = PROJECT_ROOT / "baasapi" / "run_local.sh"
    os.environ.setdefault("FLASK_DEBUG", "1")
    os.environ.setdefault("LOG_LEVEL", "DEBUG")
    os.execve("/bin/bash", ["bash", str(rl)], os.environ)


def run_migrate_sqlite_pg(ns: argparse.Namespace) -> int:
    """转发到 baasapi/migrate_sqlite_to_postgresql.py。"""
    script = PROJECT_ROOT / "baasapi" / "migrate_sqlite_to_postgresql.py"
    extra = list(ns.migrate_args or [])
    if extra and extra[0] == "--":
        extra = extra[1:]
    cmd = [sys.executable, str(script)] + extra
    _log("SQLite→PG: %s" % " ".join(cmd))
    r = subprocess.run(cmd, cwd=str(PROJECT_ROOT))
    return int(r.returncode or 0)


def run_verify(ns: argparse.Namespace) -> int:
    if ns.local:
        _apply_local_defaults()
        return _verify_local_urls()
    cfg_path = _resolve_config_path(ns.config)
    if not cfg_path.is_file():
        print("错误: 未找到部署配置: %s" % cfg_path, file=sys.stderr)
        return 1
    os.environ["DEPLOY_CONFIG"] = str(cfg_path)
    return _run_sm(["verify"], False)


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="HZTech 统一部署编排（AWS / 本地 / SQLite→PostgreSQL）。双脚本默认行为见 aws、local。"
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    pm = sub.add_parser(
        "migrate-sqlite-pg",
        help="将 SQLite 数据导入 PostgreSQL",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "等价: python3 baasapi/migrate_sqlite_to_postgresql.py [选项]\n"
            "  --dry-run          只统计各表行数\n"
            "  --prepare-sqlite     迁移前先对 SQLite 跑 init_db\n"
            "  --truncate-target    导入前清空目标业务表（危险）\n"
            "连接: DATABASE_URL 或 POSTGRES_* 或 baasapi/database_config.json"
        ),
    )
    pm.add_argument(
        "migrate_args",
        nargs=argparse.REMAINDER,
        help="转发给 migrate_sqlite_to_postgresql.py（例: --dry-run --sqlite-path PATH）",
    )
    pm.set_defaults(func=run_migrate_sqlite_pg)

    aws_epilog = """
AWS 角色默认（等同 deploy2AWS.sh）:
  --build android,web  --flutter-mode release  不迁移 DB  镜像 rsync  部署后重启  不探测
  配置默认 baasapi/deploy-aws.json（或环境变量 DEPLOY_CONFIG）
"""
    aws = sub.add_parser("aws", help="构建并同步 AWS", formatter_class=argparse.RawDescriptionHelpFormatter, epilog=aws_epilog)
    aws.add_argument(
        "--config",
        default=os.environ.get("DEPLOY_CONFIG", "baasapi/deploy-aws.json"),
        help="部署 JSON（默认 DEPLOY_CONFIG 或 baasapi/deploy-aws.json）",
    )
    aws.add_argument(
        "--build",
        default="android,web",
        help="逗号分隔: android,web,ios（默认 android,web）",
    )
    aws.add_argument(
        "--flutter-mode",
        choices=("debug", "release"),
        default="release",
        help="Android/iOS 构建模式；Web 暂始终 release（默认 release）",
    )
    aws.add_argument(
        "--db",
        "-db",
        "--db-sync",
        "--init-db",
        action="store_true",
        dest="db",
        help="部署后远程 db-sync",
    )
    aws.add_argument(
        "--db-reset",
        action="store_true",
        help="破坏性重建（需 HZTECH_ALLOW_DB_RESET=1；当前未实现）",
    )
    aws.add_argument(
        "--db-backend",
        choices=("sqlite", "postgresql"),
        default=None,
        help="写入 HZTECH_DB_BACKEND（主要影响本机侧；默认 postgresql）",
    )
    aws.add_argument(
        "--rsync-no-delete",
        action="store_true",
        help="rsync 不带 --delete，双机 Flutter 主机不 rm -rf baasapi",
    )
    aws.add_argument("--flutter-clean", action="store_true", help="构建前 flutter clean")
    aws.add_argument("--no-start", action="store_true", help="上传后不执行 restart")
    aws.add_argument("--verify", action="store_true", help="结束后 HTTP 探测（或 HZTECH_POST_DEPLOY_VERIFY=1）")
    aws.add_argument("--skip-build", action="store_true", help="跳过所有 Flutter 构建（亦认 HZTECH_SKIP_BUILD=1）")
    aws.add_argument(
        "--dart-define-file",
        default=None,
        help="覆盖 FLUTTER_DART_DEFINE_FILE",
    )
    aws.add_argument("--dry-run", action="store_true", help="只打印将执行的 server_mgr 命令")
    aws.set_defaults(func=run_aws)

    loc_epilog = """
Local 角色默认（等同 deploy2Local.sh）:
  HZTECH_DB_BACKEND=postgresql  默认不执行 init_db（仅 --db / HZTECH_DB_SYNC 等触发）
  --build android,web  --flutter-mode debug（APK debug；Web 仍 release 构建）
  执行 pip 依赖  最后 exec run_local.sh
  表结构手工 SQL 对照：baasapi/migrations/（如 add_account_tables.sql、add_account_tables.postgresql.sql、add_account_season.postgresql.sql、add_account_daily_performance.postgresql.sql）
"""
    loc = sub.add_parser(
        "local",
        help="本地依赖 + 构建 + 可选 DB + 启动",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=loc_epilog,
    )
    loc.add_argument(
        "--build",
        default="android,web",
        help="逗号分隔: android,web,ios（默认 android,web）",
    )
    loc.add_argument(
        "--flutter-mode",
        choices=("debug", "release"),
        default="debug",
        help="默认 debug（与 deploy2Local 一致）",
    )
    loc.add_argument(
        "--db",
        "-db",
        "--db-sync",
        "--init-db",
        action="store_true",
        dest="db",
        help="本地 init_db()",
    )
    loc.add_argument("--db-reset", action="store_true", help="未实现；需 HZTECH_ALLOW_DB_RESET=1")
    loc.add_argument(
        "--db-backend",
        choices=("sqlite", "postgresql"),
        default=None,
        help="HZTECH_DB_BACKEND（默认 postgresql）",
    )
    loc.add_argument("--skip-pip", action="store_true", help="跳过 install_python_deps.sh")
    loc.add_argument("--skip-build", action="store_true", help="跳过所有 Flutter 构建")
    loc.add_argument(
        "--skip-mobile-build",
        action="store_true",
        help="跳过移动端（android/ios）；等价于从 --build 去掉 mobile",
    )
    loc.add_argument("--skip-web-build", action="store_true", help="跳过 web 构建")
    loc.add_argument("--flutter-clean", action="store_true", help="构建前 flutter clean")
    loc.add_argument(
        "--no-start",
        action="store_true",
        help="不 exec run_local.sh（仅构建/DB/探测）",
    )
    loc.add_argument("--verify", action="store_true", help="探测 127.0.0.1 端口")
    loc.add_argument(
        "--dart-define-file",
        default=None,
        help="覆盖 FLUTTER_DART_DEFINE_FILE",
    )
    loc.add_argument("--dry-run", action="store_true")
    loc.set_defaults(func=run_local)

    pv = sub.add_parser("verify", help="仅 HTTP 探测（默认读 DEPLOY_CONFIG）")
    pv.add_argument(
        "--config",
        default=os.environ.get("DEPLOY_CONFIG", "baasapi/deploy-aws.json"),
        help="AWS 部署 JSON",
    )
    pv.add_argument(
        "--local",
        action="store_true",
        help="探测本机 HZTECH_LOCAL_API_PORT / HZTECH_LOCAL_WEB_PORT",
    )
    pv.set_defaults(func=run_verify)

    return p


def main(argv: list[str] | None = None) -> int:
    os.chdir(PROJECT_ROOT)
    parser = _build_parser()
    ns, rest = parser.parse_known_args(argv)
    if rest:
        print("错误: 未识别参数: %s" % rest, file=sys.stderr)
        return 2
    return int(ns.func(ns) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
