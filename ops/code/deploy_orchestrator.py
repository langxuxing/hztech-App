#!/usr/bin/env python3
"""统一部署编排：AWS 与本地。由 deploy2AWS.sh / deploy2Local.sh 薄封装调用。

详见仓库内部署规划文档；python3 aws-ops/code/deploy_orchestrator.py --help
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "baasapi"))

import deploy_ui as du


def _baasapi_python() -> str:
    """优先使用 baasapi/.venv（install_python_deps.sh 创建），与本地 PEP 668 环境及 run_local 一致。"""
    override = os.environ.get("HZTECH_PYTHON", "").strip()
    if override:
        p = Path(override)
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
    vdir = PROJECT_ROOT / "baasapi" / ".venv"
    if os.name == "nt":
        cand = vdir / "Scripts" / "python.exe"
    else:
        cand = vdir / "bin" / "python"
    if cand.is_file() and os.access(cand, os.X_OK):
        return str(cand)
    return sys.executable


def _log(msg: str) -> None:
    du.deploy_log(msg)


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


def _run_sm(
    args: list[str],
    dry_run: bool,
    *,
    extra_env: dict[str, str] | None = None,
    timeout_sec: float | None = None,
) -> int:
    cmd = [_baasapi_python(), str(PROJECT_ROOT / "baasapi" / "server_mgr.py")] + args
    if dry_run:
        _log("dry-run: %s" % cmd)
        if extra_env:
            _log("dry-run env: %r" % (extra_env,))
        if timeout_sec is not None:
            _log("dry-run timeout_sec=%r" % (timeout_sec,))
        return 0
    run_env = os.environ.copy()
    if extra_env:
        run_env.update(extra_env)
    pop_kw: dict = {"cwd": str(PROJECT_ROOT), "env": run_env}
    if timeout_sec is not None and timeout_sec > 0:
        pop_kw["timeout"] = timeout_sec
    try:
        r = subprocess.run(cmd, **pop_kw)
    except subprocess.TimeoutExpired:
        lim = timeout_sec if timeout_sec is not None else 0.0
        du.err("子进程超时（%.0fs）已中止：%s" % (lim, " ".join(cmd)))
        du.warn(
            "若网络或 PyPI 较慢，请增大 HZTECH_PIP_REMOTE_TIMEOUT_SEC；"
            "依赖已就绪可设 HZTECH_SKIP_REMOTE_PIP=1 跳过阶段 7。"
        )
        return 124
    return int(r.returncode or 0)


def _run_flutter_clean(dry_run: bool) -> int:
    cmd = ["flutter", "clean"]
    if dry_run:
        _log("dry-run: %s (cwd=flutterapp)" % cmd)
        return 0
    r = subprocess.run(cmd, cwd=str(PROJECT_ROOT / "flutterapp"))
    return int(r.returncode or 0)


def _http_probe_code(url: str) -> int:
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            return int(r.status)
    except urllib.error.HTTPError as e:
        return int(e.code)
    except OSError:
        return 0


def _verify_local_urls() -> int:
    """与 baasapi.server_mgr.run_verify_deploy 一致：支持轮询（main.py 启动较慢）。"""
    api = int(os.environ.get("HZTECH_LOCAL_API_PORT") or os.environ.get("PORT") or "9001")
    web = int(os.environ.get("HZTECH_LOCAL_WEB_PORT") or "9000")
    targets = [
        ("http://127.0.0.1:%s/api/health" % api, "BaasAPI health"),
        ("http://127.0.0.1:%s/" % web, "FlutterApp /"),
    ]
    try:
        timeout_sec = float(os.environ.get("HZTECH_POST_DEPLOY_VERIFY_TIMEOUT_SEC", "120"))
    except ValueError:
        timeout_sec = 120.0
    timeout_sec = max(5.0, timeout_sec)
    try:
        interval_sec = float(os.environ.get("HZTECH_POST_DEPLOY_VERIFY_INTERVAL_SEC", "2"))
    except ValueError:
        interval_sec = 2.0
    interval_sec = max(0.5, interval_sec)

    t0 = time.time()
    deadline = t0 + timeout_sec
    attempt = 0
    rows: list[tuple[str, str, int, bool]] = []
    ok = False
    while True:
        attempt += 1
        rows = []
        ok = True
        for url, label in targets:
            code = _http_probe_code(url)
            row_ok = code in (200, 503)
            rows.append((label, url, code, row_ok))
            if not row_ok:
                ok = False
        if ok:
            break
        if time.time() >= deadline:
            break
        time.sleep(interval_sec)

    for label, url, code, row_ok in rows:
        mark = du.I_OK if row_ok else du.I_WARN
        print("  %s %s → HTTP %s  %s" % (mark, label, code, url))
    if ok and attempt > 1:
        print(
            "%s 本地健康检查：第 %d 次探测通过（约 %.0f s）"
            % (du.I_OK, attempt, time.time() - t0)
        )
    return 0 if ok else 1


def _run_local_init_db(dry_run: bool) -> int:
    if dry_run:
        _log("dry-run: init_db()")
        return 0
    env = os.environ.copy()
    env["PYTHONPATH"] = str(PROJECT_ROOT)
    r = subprocess.run(
        [
            _baasapi_python(),
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


def _should_run_remote_pip() -> bool:
    """与 server_mgr._remote_pip_install_wanted 一致：HZTECH_SKIP_REMOTE_PIP=1 时不跑远端 pip。
    双机且 HZTECH_DEPLOY_APK_ONLY=1 时仅推 APK、未改 BaasAPI 代码树，默认跳过阶段 7。"""
    v = os.environ.get("HZTECH_SKIP_REMOTE_PIP", "").strip().lower()
    if v in ("1", "true", "yes"):
        return False
    if _env_truthy("HZTECH_DEPLOY_APK_ONLY"):
        sm = _load_server_mgr()
        if sm.split_dual_deploy():
            return False
    return True


def _pip_remote_timeout_sec() -> float | None:
    """阶段 7 pip-remote 超时（秒）。HZTECH_PIP_REMOTE_TIMEOUT_SEC 未设时默认 3600；0 或负数表示不限时。"""
    raw = os.environ.get("HZTECH_PIP_REMOTE_TIMEOUT_SEC", "3600").strip()
    if raw == "":
        return 3600.0
    try:
        v = float(raw)
    except ValueError:
        return 3600.0
    if v <= 0:
        return None
    return v


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
    os.environ.setdefault("HZTECH_APP_ANDROID_APK", "hztech-app-release.apk")


def _apply_aws_defaults() -> None:
    os.environ.setdefault("HZTECH_SKIP_IOS_BUILD", "1")
    os.environ.setdefault("HZTECH_DB_BACKEND", "postgresql")
    os.environ.setdefault(
        "FLUTTER_DART_DEFINE_FILE", "flutterapp/dart_defines/production.json"
    )
    os.environ.setdefault("HZTECH_APP_ANDROID_APK", "hztech-app-release.apk")


def run_aws(ns: argparse.Namespace) -> int:
    cfg_path = _resolve_config_path(ns.config)
    if not cfg_path.is_file():
        du.err("未找到部署配置: %s" % cfg_path)
        return 1
    os.environ["DEPLOY_CONFIG"] = str(cfg_path)
    _apply_aws_defaults()
    if _env_truthy("HZTECH_DEPLOY_APK_ONLY"):
        # 仅上传 release APK：避免构建 Web、避免全量 rsync（见 server_mgr.rsync_sync）
        ns.build = "android"
    if ns.dart_define_file:
        os.environ["FLUTTER_DART_DEFINE_FILE"] = ns.dart_define_file
    if ns.db_backend:
        os.environ["HZTECH_DB_BACKEND"] = ns.db_backend
    if "HZTECH_API_BASE_URL" not in os.environ:
        sm = _load_server_mgr()
        os.environ["HZTECH_API_BASE_URL"] = sm.default_hztech_api_base_url()

    skip_build = ns.skip_build or os.environ.get("HZTECH_SKIP_BUILD", "").strip() == "1"
    bset = _parse_build_set(ns.build)
    skip_mobile = getattr(ns, "skip_mobile_build_aws", False) or os.environ.get(
        "HZTECH_SKIP_MOBILE_BUILD", ""
    ).strip().lower() in ("1", "true", "yes")
    if skip_mobile:
        bset.discard("android")
        bset.discard("ios")
    if skip_build:
        bset = set()

    if ns.db_reset:
        if os.environ.get("HZTECH_ALLOW_DB_RESET") != "1":
            du.err("--db-reset 需同时设置环境变量 HZTECH_ALLOW_DB_RESET=1")
            return 2
        du.err("数据库破坏性重建尚未实现，请使用 init_db/db-sync 迁移。")
        return 3

    build_desc = ",".join(sorted(bset)) if bset else "（无）"
    if skip_build:
        build_desc = "（已跳过）"
    aws_quiet = _env_truthy("HZTECH_DEPLOY_QUIET")
    T = du.DEPLOY_STAGE_TOTAL_AWS
    # 阶段 1–9 始终打印；HZTECH_DEPLOY_QUIET 仅影响 rsync/SSH/pip 刷屏（server_mgr）与下方细粒度 ok/step
    du.title_staged(
        1,
        T,
        du.I_ROCKET,
        "AWS 部署流水线",
        sub=(
            "%s 共 %d 个阶段　｜　配置见 deploy-aws.json\n"
            "   %s 流程：说明 → Flutter → rsync → 可选 DB → 远端 pip → restart → HTTP"
            % (du.I_PIN, T, du.I_CLIP)
        ),
    )
    print("   %s 配置文件: %s" % (du.I_CLIP, cfg_path))
    print("   %s API 基址: %s" % (du.I_LINK, os.environ.get("HZTECH_API_BASE_URL", "")))
    print(
        "   %s 构建目标: %s　｜　skip_build=%s"
        % (du.I_PACKAGE, build_desc, skip_build)
    )
    du.hr()
    du.stage_step(
        2,
        T,
        du.I_TIP,
        "本机 Python 依赖：不在此流水线安装（远端 pip 为阶段 7，进程拉起为阶段 8）",
    )

    if ns.flutter_clean:
        du.stage_step(3, T, du.I_TIME, "清理 Flutter 构建缓存（flutter clean）…")
        rc = _run_flutter_clean(ns.dry_run)
        if rc != 0:
            return rc
        if not aws_quiet:
            du.ok("flutter clean 已完成")
    else:
        du.stage_step(3, T, du.I_SKIP, "跳过：未指定 --flutter-clean")

    if not skip_build and bset:
        du.stage_step(
            4,
            T,
            du.I_PACKAGE,
            "Flutter 构建（%s）…" % ",".join(sorted(bset)),
        )
        if "android" in bset:
            mode_zh = "Release" if ns.flutter_mode == "release" else "Debug"
            du.step(du.I_PHONE, "📱 Android")
            if not aws_quiet:
                du.step(
                    du.I_PHONE,
                    "   构建 APK（%s，Gradle 首次可能较慢）…" % mode_zh,
                )
            if ns.flutter_mode == "release":
                rc = _run_sm(["build"], ns.dry_run)
            else:
                rc = _run_sm(["build-debug"], ns.dry_run)
            if rc != 0:
                return rc
            if not aws_quiet:
                du.ok("APK 构建阶段结束")
        if "ios" in bset:
            if not _ios_build_allowed():
                if not aws_quiet:
                    du.skip("跳过 iOS：将 HZTECH_SKIP_IOS_BUILD 设为 0 可启用 IPA 构建")
            else:
                du.step(du.I_APPLE, "🍎 iOS")
                if not aws_quiet:
                    du.step(du.I_APPLE, "   构建 IPA（release）…")
                rc = _run_sm(["build-ios"], ns.dry_run)
                if rc != 0:
                    return rc
                if not aws_quiet:
                    du.ok("IPA 构建阶段结束")
        if "web" in bset:
            if ns.flutter_mode == "debug" and not aws_quiet:
                du.tip("Web 暂仅支持 release，已忽略 --flutter-mode debug")
            du.step(du.I_GLOBE, "🌐 Web")
            if not aws_quiet:
                du.step(du.I_GLOBE, "   构建 Flutter Web（release）…")
            rc = _run_sm(["build-web"], ns.dry_run)
            if rc != 0:
                if not aws_quiet:
                    du.warn("Web 构建失败：将继续同步，远端静态站可能返回 503")
            elif not aws_quiet:
                du.ok("Web 构建阶段结束")
    else:
        du.stage_step(
            4,
            T,
            du.I_SKIP,
            "跳过：skip_build 或无可构建目标（android/ios/web）",
        )

    deploy_args = ["deploy", "--no-start"]
    if ns.rsync_no_delete:
        deploy_args.append("--rsync-no-delete")
    du.stage_step(
        5,
        T,
        du.I_UPLOAD,
        "同步文件到服务器（rsync；HZTECH_DEPLOY_APK_ONLY=1 时仅推 apk，双机推 BaasAPI + Flutter）…",
    )
    if aws_quiet:
        du.tip(
            "静默模式：rsync 仍会逐步打印「目标 + 开始/结束耗时」及 --stats 传输汇总（无逐文件 -v 列表）；"
            "双机多段可能各需数分钟。需逐文件请 HZTECH_DEPLOY_QUIET=0 ./deploy2AWS.sh"
        )
        sys.stdout.flush()
    rc = _run_sm(deploy_args, ns.dry_run)
    if rc != 0:
        return rc
    if not aws_quiet:
        du.ok("文件同步完成")

    if _should_run_db_migrate(ns.db):
        du.stage_step(6, T, du.I_DB, "远程数据库迁移（db-sync / init_db）…")
        rc = _run_sm(["db-sync"], ns.dry_run)
        if rc != 0:
            return rc
        if not aws_quiet:
            du.ok("数据库迁移已执行")
    else:
        du.stage_step(
            6,
            T,
            du.I_SKIP,
            "跳过：未启用远程数据库迁移（--db / HZTECH_DB_SYNC 等）",
        )

    dbg_timing = _env_truthy("HZTECH_DEPLOY_DEBUG_TIMING")
    if dbg_timing:
        du.tip(
            "HZTECH_DEPLOY_DEBUG_TIMING=1：阶段 7 pip 与阶段 8 restart 将打印 [deploy-timing] 分段耗时。"
        )
        sys.stdout.flush()

    if _should_run_remote_pip():
        du.stage_step(
            7,
            T,
            du.I_TIME,
            "远端 pip install -r baasapi/requirements.txt（双机则两台依次执行）…",
        )
        pip_timeout = _pip_remote_timeout_sec()
        du.tip(
            "阶段 7：pip 子进程强制详细输出（完整 pip 日志）。"
            + (
                " 超时上限 %.0f 秒（HZTECH_PIP_REMOTE_TIMEOUT_SEC；设为 0 表示不限时）。"
                % pip_timeout
                if pip_timeout
                else " 未启用超时（HZTECH_PIP_REMOTE_TIMEOUT_SEC=0）。"
            )
        )
        sys.stdout.flush()
        t_pip = time.time()
        rc = _run_sm(
            ["pip-remote"],
            ns.dry_run,
            extra_env={"HZTECH_DEPLOY_QUIET": "0"},
            timeout_sec=pip_timeout,
        )
        if dbg_timing:
            print(
                "%s [deploy-timing] 阶段 7（pip-remote）总耗时 %.2fs"
                % (du.I_TIME, time.time() - t_pip),
                flush=True,
            )
        if rc != 0:
            return rc
        if not aws_quiet:
            du.ok("远端 requirements 已安装（或已满足）")
    else:
        _v_skip = os.environ.get("HZTECH_SKIP_REMOTE_PIP", "").strip().lower()
        if _v_skip in ("1", "true", "yes"):
            _pip_skip = "HZTECH_SKIP_REMOTE_PIP=1（不在此流水线执行远端 pip）"
        else:
            _pip_skip = (
                "HZTECH_DEPLOY_APK_ONLY=1 且双机：仅推 APK（含 BaasAPI 与 Flutter），未改 BaasAPI 代码，跳过远端 pip"
            )
        du.stage_step(7, T, du.I_SKIP, "跳过：%s" % _pip_skip)

    if not ns.no_start:
        restart_args = ["restart"]
        if _env_truthy("HZTECH_DEPLOY_APK_ONLY"):
            sm = _load_server_mgr()
            if sm.split_dual_deploy():
                restart_args = ["restart-web"]
        _st8_title = "重启远端（合并 SSH：停旧进程 + 目录 + nohup；本阶段不含 pip）…"
        if restart_args == ["restart-web"]:
            _st8_title = "重启 Flutter 静态站（仅 serve_web_static；双机 APK-only）…"
        du.stage_step(8, T, du.I_REFRESH, _st8_title)
        if restart_args == ["restart-web"]:
            du.tip(
                "阶段 8：仅 Flutter 静态机；无 pip 时一次 SSH（pkill+清目录+nohup+sleep1）。"
                "HZTECH_DEPLOY_DEBUG_TIMING=1 可看各步耗时。"
            )
        else:
            du.tip(
                "阶段 8：server_mgr 已合并远程命令；无 pip 时 BaasAPI / Flutter 各约 1 次 SSH（同机则 1 次起双进程）。"
                "编排器传 HZTECH_SKIP_REMOTE_PIP=1 时不跑远端 pip。耗时至多为握手 RTT 与 sleep 1；"
                "HZTECH_DEPLOY_DEBUG_TIMING=1 可细分。"
            )
        sys.stdout.flush()
        t_restart = time.time()
        rc = _run_sm(
            restart_args,
            ns.dry_run,
            extra_env={"HZTECH_SKIP_REMOTE_PIP": "1"},
        )
        if dbg_timing:
            print(
                "%s [deploy-timing] 阶段 8（restart）总耗时 %.2fs"
                % (du.I_TIME, time.time() - t_restart),
                flush=True,
            )
        if rc != 0:
            return rc
        if not aws_quiet:
            du.ok("远端进程已拉起")
    else:
        du.stage_step(
            8,
            T,
            du.I_SKIP,
            "跳过：--no-start（未重启远端服务）",
        )

    do_verify = ns.verify or _env_truthy("HZTECH_POST_DEPLOY_VERIFY")
    if do_verify:
        du.stage_step(
            9,
            T,
            du.I_SEARCH,
            "HTTP 健康检查（API /health 与 Flutter 静态根路径）…",
        )
    else:
        du.stage_step(
            9,
            T,
            du.I_SKIP,
            "跳过：未启用部署后验证（可加 --verify 或 HZTECH_POST_DEPLOY_VERIFY=1）",
        )
    if do_verify:
        rc = _run_sm(["verify"], ns.dry_run)
        if rc != 0:
            return rc

    if not aws_quiet:
        _log(
            "摘要: target=aws config=%s sync_mirror=%s db_migrate=%s remote_pip=%s restart=%s verify=%s dry_run=%s"
            % (
                cfg_path.name,
                not ns.rsync_no_delete,
                _should_run_db_migrate(ns.db),
                _should_run_remote_pip(),
                not ns.no_start,
                do_verify,
                ns.dry_run,
            )
        )
        du.hr()
        du.step(du.I_DONE, "AWS 部署流水线已结束（请根据上方 ✅/⚠️ 确认各步结果）")
    elif not do_verify:
        print("%s AWS 部署完成（未执行 HTTP 验证；可设 HZTECH_POST_DEPLOY_VERIFY=1）" % du.I_OK)
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
            du.err("--db-reset 需同时设置环境变量 HZTECH_ALLOW_DB_RESET=1")
            return 2
        du.err("数据库破坏性重建尚未实现。")
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
    T = du.DEPLOY_STAGE_TOTAL_LOCAL
    du.title_staged(
        1,
        T,
        du.I_ROCKET,
        "本地开发流水线",
        sub="共 %d 个阶段；完成后将启动 run_local.sh（除非指定 --no-start）" % T,
    )
    print(
        "   %s 数据库: %s　｜　init_db=%s"
        % (
            du.I_DB,
            os.environ.get("HZTECH_DB_BACKEND", "postgresql"),
            "是" if will_db else "否（默认）",
        )
    )
    print(
        "   %s 构建: %s　｜　flutter-mode=%s（Web 始终 release）"
        % (
            du.I_PACKAGE,
            ",".join(sorted(bset)) if bset else "（跳过）",
            ns.flutter_mode,
        )
    )
    print(
        "   %s 端口 API=%s　Web 静态=%s　WEB_STATIC=%s"
        % (
            du.I_LINK,
            os.environ.get("HZTECH_LOCAL_API_PORT"),
            os.environ.get("HZTECH_LOCAL_WEB_PORT"),
            os.environ.get("HZTECH_LOCAL_WEB_STATIC"),
        )
    )
    du.hr()

    pip_cmd = ["bash", str(PROJECT_ROOT / "ops" / "code" / "install_python_deps.sh")]
    if not skip_pip:
        if ns.dry_run:
            du.stage_step(2, T, du.I_TIME, "[dry-run] 将执行 install_python_deps.sh…")
            _log("dry-run: %s" % pip_cmd)
        else:
            du.stage_step(2, T, du.I_TIME, "安装本机 Python 依赖（install_python_deps.sh）…")
            r = subprocess.run(pip_cmd, cwd=str(PROJECT_ROOT))
            if r.returncode != 0:
                return int(r.returncode)
            du.ok("本机依赖就绪")
    else:
        du.stage_step(2, T, du.I_SKIP, "跳过：--skip-pip 或 HZTECH_SKIP_PIP_INSTALL")

    if ns.flutter_clean:
        du.stage_step(3, T, du.I_TIME, "清理 Flutter 构建缓存（flutter clean）…")
        rc = _run_flutter_clean(ns.dry_run)
        if rc != 0:
            return rc
        du.ok("flutter clean 已完成")
    else:
        du.stage_step(3, T, du.I_SKIP, "跳过：未指定 --flutter-clean")

    if not skip_build and bset:
        du.stage_step(
            4,
            T,
            du.I_PACKAGE,
            "Flutter 构建（%s）…" % ",".join(sorted(bset)),
        )
        if "android" in bset:
            du.step(
                du.I_PHONE,
                "构建 Android（%s）…"
                % ("Release" if ns.flutter_mode == "release" else "Debug"),
            )
            if ns.flutter_mode == "release":
                rc = _run_sm(["build"], ns.dry_run)
            else:
                rc = _run_sm(["build-debug"], ns.dry_run)
            if rc != 0:
                return rc
            du.ok("APK 构建完成")
        if "ios" in bset:
            if not _ios_build_allowed():
                du.skip("跳过 iOS（HZTECH_SKIP_IOS_BUILD 未设为 0）")
            else:
                du.step(du.I_APPLE, "构建 iOS IPA…")
                rc = _run_sm(["build-ios"], ns.dry_run)
                if rc != 0:
                    return rc
                du.ok("IPA 构建完成")
        if "web" in bset:
            if ns.flutter_mode == "debug":
                du.tip("Web 暂仅 release 构建")
            du.step(du.I_GLOBE, "构建 Flutter Web…")
            rc = _run_sm(["build-web"], ns.dry_run)
            if rc != 0:
                du.warn("Web 构建失败")
            else:
                du.ok("Web 构建完成")
    else:
        du.stage_step(
            4,
            T,
            du.I_SKIP,
            "跳过：--skip-build 或当前无可构建目标（android/ios/web）",
        )

    du.stage_step(5, T, du.I_CLIP, "文件同步：无需 rsync（本地 workspace）")

    if will_db:
        du.stage_step(6, T, du.I_DB, "本地 init_db（表结构迁移）…")
        rc = _run_local_init_db(ns.dry_run)
        if rc != 0:
            return rc
        du.ok("init_db 已完成")
    else:
        du.stage_step(
            6,
            T,
            du.I_SKIP,
            "跳过：未启用数据库迁移（默认不加 --db；可设 HZTECH_DB_SYNC）",
        )

    do_verify = ns.verify or _env_truthy("HZTECH_POST_DEPLOY_VERIFY")
    if do_verify:
        du.stage_step(7, T, du.I_SEARCH, "本机 HTTP 健康探测（127.0.0.1 API / Web）…")
        rc = _verify_local_urls()
        if rc != 0:
            return rc
    else:
        du.stage_step(
            7,
            T,
            du.I_SKIP,
            "跳过：未指定 --verify 且 HZTECH_POST_DEPLOY_VERIFY 未开启",
        )

    if ns.no_start:
        du.stage_step(8, T, du.I_SKIP, "跳过启动：--no-start")
        _log(
            "摘要: target=local build=%s db_migrate=%s start=False verify=%s"
            % (
                ",".join(sorted(bset)) or "(skip)",
                _should_run_db_migrate(ns.db),
                do_verify,
            )
        )
        return 0

    if ns.dry_run:
        du.stage_step(8, T, du.I_REFRESH, "[dry-run] 将 exec baasapi/run_local.sh…")
        _log("dry-run: 未 exec run_local.sh")
        return 0

    du.stage_step(8, T, du.I_REFRESH, "启动本机 BaasAPI + 静态站（run_local.sh）…")
    _log("exec: baasapi/run_local.sh")

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
    cmd = [_baasapi_python(), str(script)] + extra
    _log("SQLite→PG: %s" % " ".join(cmd))
    r = subprocess.run(cmd, cwd=str(PROJECT_ROOT))
    return int(r.returncode or 0)


def run_verify(ns: argparse.Namespace) -> int:
    if ns.local:
        _apply_local_defaults()
        return _verify_local_urls()
    cfg_path = _resolve_config_path(ns.config)
    if not cfg_path.is_file():
        du.err("未找到部署配置: %s" % cfg_path)
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
直接运行本子命令默认仍含 android 构建；deploy2AWS.sh 会导出 HZTECH_SKIP_MOBILE_BUILD=1（仅 web）、
HZTECH_DEPLOY_SKIP_APK_SYNC=1、HZTECH_DEPLOY_APK_ONLY=0；另默认 HZTECH_DEPLOY_QUIET=1（rsync/SSH/pip 少刷屏）、
HZTECH_POST_DEPLOY_VERIFY=1（结束 HTTP 健康检查）。AWS 流水线阶段 1/9–9/9；rsync/pip 更详细: HZTECH_DEPLOY_QUIET=0。
阶段 7 为远端 pip（默认详细 pip 日志 + 3600s 超时，HZTECH_PIP_REMOTE_TIMEOUT_SEC / 0=不限）；阶段 8 为 restart。
卡顿排查: HZTECH_DEPLOY_DEBUG_TIMING=1；跳过远端 pip: HZTECH_SKIP_REMOTE_PIP=1。
仅推 APK 时设 HZTECH_DEPLOY_APK_ONLY=1（双机时 rsync 到 BaasAPI 与 Flutter 静态机；阶段 7 跳过 pip、阶段 8 仅 restart-web）。
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
        "--skip-mobile-build",
        action="store_true",
        dest="skip_mobile_build_aws",
        help="跳过 android/ios 构建（亦认 HZTECH_SKIP_MOBILE_BUILD=1）",
    )
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
  --build android,web  --flutter-mode release（APK：hztech-app-release.apk；Web 仍 release 构建）
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
        default="release",
        help="默认 release（hztech-app-release.apk；调试可传 --flutter-mode debug）",
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
        du.err("未识别参数: %s" % rest)
        return 2
    return int(ns.func(ns) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
