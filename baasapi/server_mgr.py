"""AWS 部署配置与 SSH 管理。从 baasapi/deploy-aws.json 读取配置；盘符目录为 baasapi/、flutterapp/，
配置段键名仍为 flutterapp / baasapi（ports：flutterapp_port、baasapi_port）。兼容旧键 web / api。

双机部署（同时配置 flutterapp 与 baasapi 段且 host/remote_path 不同）：BaasAPI 主机同步完整后端（含数据库目录）；Flutter 静态机
仅同步 apk/、flutterapp/build/web/、flutterapp/web_static/（Flask 静态进程），不同步 baasapi/，并 rm 清理历史上误留在远端的 baasapi/。
若两段指向同一台同一 remote_path，则按单机处理（整包 baasapi + flutterapp/build/web + flutterapp/web_static），避免双机第二步清空 BaasAPI 目录。"""
from pathlib import Path
from typing import Optional
import json
import os
import shlex
import shutil
import subprocess
import sys
import time

# ops/read_deploy_config 等用 importlib 按路径加载本模块时，sys.path 不含 baasapi，同目录 deploy_ui 需可解析。
_baasapi_dir = str(Path(__file__).resolve().parent)
if _baasapi_dir not in sys.path:
    sys.path.insert(0, _baasapi_dir)
import deploy_ui as du

# 项目根目录（baasapi 的上一级）
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DEPLOY_CONFIG_PATH = PROJECT_ROOT / "baasapi" / "deploy-aws.json"
# 兼容旧名（仅文档/外部引用）
CONFIG_PATH = DEFAULT_DEPLOY_CONFIG_PATH
GRADLEW = PROJECT_ROOT / "gradlew"
flutterapp = PROJECT_ROOT / "flutterapp"
FLUTTER_WEB_STATIC_DIR = flutterapp / "web_static"
# 远端 pip 用（相对项目根）；双机 Flutter 机只装 Flask
FLUTTER_WEB_STATIC_REQ_REL = "flutterapp/web_static/requirements-web-static.txt"
APK_DEBUG_DIR = PROJECT_ROOT / "app" / "build" / "outputs" / "apk" / "debug"
FLUTTER_APK_DIR = flutterapp / "build" / "app" / "outputs" / "flutter-apk"
FLUTTER_IPA_DIR = flutterapp / "build" / "ios" / "ipa"
# 生成 APK 放入项目根下 apk/，部署后对应 AWS 上 hztechapp/apk/（见 deploy-aws.json remote_path）
APK_DIR = PROJECT_ROOT / "apk"
# 与 deploy2AWS.sh / deploy2Local.sh 默认 release 产物名一致
DEFAULT_APK_NAME_RELEASE = "hztech-app-release.apk"
DEFAULT_APK_NAME_DEBUG = "hztech-app-debug.apk"
# iOS：flutter build ipa 产物复制到 ipa/，随 rsync 一并上传（与 apk/ 并列）
IPA_DIR = PROJECT_ROOT / "ipa"
DEFAULT_IPA_NAME = "禾正量化-release.ipa"

# 远端启动 main.py 时注入（与 install_on_aws.sh 一致）。勿用本机 HZTECH_TRADINGBOT_CTRL_DIR，避免 Mac 路径传到 EC2。
_REMOTE_TRADINGBOT_CTRL_DIR = (
    os.environ.get("HZTECH_REMOTE_TRADINGBOT_CTRL_DIR", "/home/ec2-user/Alpha").strip()
    or "/home/ec2-user/Alpha"
)
_REMOTE_TRADINGBOT_ACCOUNT_LIST_SOURCE = (
    os.environ.get("HZTECH_REMOTE_TRADINGBOT_ACCOUNT_LIST_SOURCE", "database").strip()
    or "database"
)


def _deploy_quiet() -> bool:
    """HZTECH_DEPLOY_QUIET=1：rsync/SSH 捕获输出、省略 -v 与 pip 进度，失败时再打印。

    rsync 在静默下会注入 --stats，并打印每段 label、耗时与统计摘要（见 _run_rsync）。
    """
    v = os.environ.get("HZTECH_DEPLOY_QUIET", "").strip().lower()
    return v in ("1", "true", "yes")


def _deploy_debug_ssh_timing() -> bool:
    """HZTECH_DEPLOY_DEBUG_TIMING=1：restart 内每次 SSH 前后打印步骤名与耗时（编排器 AWS 阶段 8）。"""
    v = os.environ.get("HZTECH_DEPLOY_DEBUG_TIMING", "").strip().lower()
    return v in ("1", "true", "yes")


def _rsync_compress_flags() -> list[str]:
    """-v 会逐文件刷屏；静默模式下用 -az。"""
    return ["-az"] if _deploy_quiet() else ["-avz"]


def _with_rsync_quiet_stats(cmd: list) -> list:
    """静默 rsync 时插入 --stats，结束时 stderr 含传输汇总（不启用逐文件 -v）。"""
    out = list(cmd)
    if "--stats" in out:
        return out
    try:
        ei = out.index("-e")
    except ValueError:
        if len(out) >= 2:
            return out[:2] + ["--stats"] + out[2:]
        return out + ["--stats"]
    return out[:ei] + ["--stats"] + out[ei:]


def _print_rsync_stats_block(stderr: str) -> None:
    if not stderr or not stderr.strip():
        return
    for line in stderr.splitlines():
        s = line.strip()
        if s:
            print("   %s %s" % (du.I_CLIP, s), flush=True)


def _remote_baasapi_start_env(remote_path: str, api_port: int) -> str:
    """SSH 一行前缀：MOBILEAPP_ROOT、PORT、交易机器人目录与账户列表来源。"""
    rp = shlex.quote(remote_path)
    port_q = shlex.quote(str(api_port))
    ctrl = shlex.quote(_REMOTE_TRADINGBOT_CTRL_DIR)
    als = shlex.quote(_REMOTE_TRADINGBOT_ACCOUNT_LIST_SOURCE)
    return (
        f"MOBILEAPP_ROOT={rp} PORT={port_q} "
        f"HZTECH_TRADINGBOT_CTRL_DIR={ctrl} "
        f"HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE={als} "
    )


def _ios_build_requested() -> bool:
    """是否执行 iOS IPA 构建。默认不编译；仅当 HZTECH_SKIP_IOS_BUILD 为 0/false/no 时编译。"""
    v = os.environ.get("HZTECH_SKIP_IOS_BUILD", "1").strip().lower()
    return v in ("0", "false", "no")


def resolve_deploy_config_path() -> Path:
    """部署 JSON 路径：环境变量 DEPLOY_CONFIG（相对路径相对项目根）。"""
    raw = os.environ.get("DEPLOY_CONFIG", "").strip()
    if not raw:
        return DEFAULT_DEPLOY_CONFIG_PATH
    p = Path(raw)
    return p.resolve() if p.is_absolute() else (PROJECT_ROOT / p).resolve()


def load_config():
    path = resolve_deploy_config_path()
    if not path.is_file():
        raise FileNotFoundError("未找到部署配置: %s" % path)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def default_hztech_api_base_url() -> str:
    """未设置 HZTECH_API_BASE_URL 时：优先 deploy-aws.json `web_https_api_base_url`（公网 nginx 入口），否则 EC2 直连。"""
    c = load_config()
    pub = c.get("web_https_api_base_url")
    if isinstance(pub, str) and pub.strip():
        u = pub.strip()
        return u if u.endswith("/") else u + "/"
    scheme = str(c.get("scheme") or "http")
    api_port = int(
        c.get("baasapi_port", c.get("app_port", c.get("web_port", 9001)))
    )
    fa = c.get("flutterapp") if isinstance(c.get("flutterapp"), dict) else {}
    ba = c.get("baasapi") if isinstance(c.get("baasapi"), dict) else {}
    if not fa:
        fa = c.get("web") if isinstance(c.get("web"), dict) else {}
    if not ba:
        ba = c.get("api") if isinstance(c.get("api"), dict) else {}
    dual = isinstance(fa, dict) and isinstance(ba, dict)
    wh = (fa.get("host") or c.get("host") or "").strip()
    ah = (ba.get("host") or "").strip()
    if not dual and not ah:
        ah = wh
    host = ah if dual or ah else wh
    return "%s://%s:%s/" % (scheme, host, api_port)


def _top_level_base(c: dict) -> dict:
    """合并 deploy-aws.json 顶层字段，并统一端口名（flutterapp_port / web_port → web_port）。"""
    keys = (
        "name",
        "scheme",
        "web_port",
        "app_port",
        "flutterapp_port",
        "baasapi_port",
        "user",
        "key",
        "ssh_opts",
    )
    base = {k: c[k] for k in keys if k in c}
    wport = c.get("flutterapp_port", c.get("web_port", 9000))
    aport = c.get("baasapi_port", c.get("app_port", 9001))
    base["web_port"] = int(wport)
    base["app_port"] = int(aport)
    return base


def target_config(role: str) -> dict:
    """合并顶层字段与分应用段。role 为 ``flutterapp``（Flutter 静态等）或 ``baasapi``（后端 API）。

    兼容旧键：``web`` / ``api`` 在未提供新键时仍可读。
    """
    c = load_config()
    base = _top_level_base(c)
    nested = None
    if role == "flutterapp":
        nested = c.get("flutterapp")
        if not isinstance(nested, dict):
            nested = c.get("web")
    elif role == "baasapi":
        nested = c.get("baasapi")
        if not isinstance(nested, dict):
            nested = c.get("api")
    else:
        raise KeyError("target_config role 须为 'flutterapp' 或 'baasapi'，实为 %r" % (role,))
    if isinstance(nested, dict):
        return {**base, **nested}
    if "host" in c and "remote_path" in c:
        return {**base, **{k: c[k] for k in ("host", "port", "remote_path") if k in c}}
    raise KeyError(
        "deploy-aws.json 缺少 flutterapp/baasapi 配置段（或旧版 web/api），或旧版 host/remote_path"
    )


def has_dual_deploy() -> bool:
    c = load_config()
    has_fa = isinstance(c.get("flutterapp"), dict) or isinstance(c.get("web"), dict)
    has_ba = isinstance(c.get("baasapi"), dict) or isinstance(c.get("api"), dict)
    return has_fa and has_ba


def _deploy_same_remote_target() -> bool:
    """flutterapp 与 baasapi 是否同一 SSH 目标（同 host、port、remote_path）。

    为 True 时不可走双机 rsync 第二步（会清空远端 baasapi/），应按单机同步并推送 build/web。
    """
    if not has_dual_deploy():
        return False
    fa = target_config("flutterapp")
    ba = target_config("baasapi")
    return (
        fa["host"] == ba["host"]
        and fa["remote_path"] == ba["remote_path"]
        and int(fa.get("port", 22)) == int(ba.get("port", 22))
    )


def split_dual_deploy() -> bool:
    """配置里有两段且物理上分两台机器部署。"""
    return has_dual_deploy() and not _deploy_same_remote_target()


def _deploy_apk_only_enabled() -> bool:
    v = os.environ.get("HZTECH_DEPLOY_APK_ONLY", "").strip().lower()
    return v in ("1", "true", "yes")


def _deploy_skip_apk_sync() -> bool:
    """为真时：不向任一端同步本机 apk/（全量 rsync 仍排除 BaasAPI 根镜像中的 apk/，由单独步骤推送）。"""
    v = os.environ.get("HZTECH_DEPLOY_SKIP_APK_SYNC", "").strip().lower()
    return v in ("1", "true", "yes")


def _rsync_apk_dir_to_host(cfg: dict, rsync_mirror: bool, short_label: str) -> None:
    """将本机项目根 apk/ 目录同步到远端 ``remote_path/apk/``（与 ``main.py`` / APK 直链一致）。"""
    if _deploy_skip_apk_sync():
        return
    apk_src = PROJECT_ROOT / "apk"
    if not apk_src.is_dir():
        return
    ssh_e = _rsync_ssh_e(cfg)
    remote_base = f"{cfg['user']}@{cfg['host']}:{cfg['remote_path']}"
    rp = cfg["remote_path"]
    run_ssh("mkdir -p %s" % shlex.quote(rp + "/apk"), cfg=cfg)
    del_flags = ["--delete"] if rsync_mirror else []
    _run_rsync(
        ["rsync"]
        + _rsync_compress_flags()
        + del_flags
        + ["-e", ssh_e, str(apk_src) + "/", remote_base + "/apk/"],
        label="%s｜本机 apk/ → %s/apk/" % (short_label, remote_base),
    )


def _rsync_release_apk_only_to_host(cfg: dict) -> None:
    """将本机 apk/hztech-app-release.apk 同步到远端 remote_path/apk/（单文件，不带全量镜像）。"""
    apk_path = APK_DIR / DEFAULT_APK_NAME_RELEASE
    if not apk_path.is_file():
        raise FileNotFoundError(
            "未找到 %s，请先构建: python3 baasapi/server_mgr.py build"
            % apk_path
        )
    ssh_e = _rsync_ssh_e(cfg)
    remote_base = "%s@%s:%s" % (cfg["user"], cfg["host"], cfg["remote_path"])
    rp = cfg["remote_path"]
    run_ssh("mkdir -p %s" % shlex.quote(rp + "/apk"), cfg=cfg)
    _run_rsync(
        ["rsync"]
        + _rsync_compress_flags()
        + [
            "-e",
            ssh_e,
            str(apk_path),
            remote_base + "/apk/" + apk_path.name,
        ],
        label="仅 APK　｜　%s → %s/apk/%s"
        % (apk_path.name, remote_base, apk_path.name),
    )


def get_ssh_target():
    """返回 (user@host, key_path) 用于 SSH/rsync（默认 FlutterApp 主机）。"""
    c = target_config("flutterapp")
    key = PROJECT_ROOT / c["key"]
    return f"{c['user']}@{c['host']}", str(key)


def get_remote_path():
    """远程 FlutterApp 部署目录。"""
    return target_config("flutterapp")["remote_path"]


def _ssh_transport_opts(cfg: dict) -> list[str]:
    """与 rsync -e 一致：keepalive、超时，并合并 deploy-aws.json 的 ssh_opts。"""
    return [
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "BatchMode=yes",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=6",
        "-o",
        "TCPKeepAlive=yes",
        "-o",
        "ConnectTimeout=30",
    ] + list(cfg.get("ssh_opts", []))


def ssh_cmd(remote_cmd=None, cfg=None):
    """构建 ssh 命令。remote_cmd 为 None 时打开交互 shell。cfg 默认 FlutterApp 主机。"""
    c = cfg if cfg is not None else target_config("flutterapp")
    key = PROJECT_ROOT / c["key"]
    port = c.get("port", 22)
    base = (
        ["ssh", "-i", str(key), "-p", str(port)]
        + _ssh_transport_opts(c)
        + [f"{c['user']}@{c['host']}"]
    )
    if remote_cmd is not None:
        base.append(remote_cmd)
    return base


def _run_ssh_timed(step_label: str, remote_cmd, check=True, cfg=None, retries: int = 3) -> None:
    """run_ssh 包装：HZTECH_DEPLOY_DEBUG_TIMING=1 时打印本步耗时（用于远端 restart 排查）。"""
    if not _deploy_debug_ssh_timing():
        run_ssh(remote_cmd, check=check, cfg=cfg, retries=retries)
        return
    host = "（默认 flutterapp 配置）"
    if cfg is not None:
        host = "%s@%s" % (cfg.get("user", "?"), cfg.get("host", "?"))
    print("%s [deploy-timing] ▶ %s　%s" % (du.I_TIME, step_label, host), flush=True)
    t0 = time.time()
    try:
        run_ssh(remote_cmd, check=check, cfg=cfg, retries=retries)
    finally:
        print(
            "%s [deploy-timing] ◼ %s　%.2fs"
            % (du.I_TIME, step_label, time.time() - t0),
            flush=True,
        )


def run_ssh(remote_cmd, check=True, cfg=None, retries: int = 3):
    """在 AWS 上执行单条命令。check=False 时忽略非零退出码（如 pkill 无匹配）。

    对 SSH 退出码 255（连接被关闭、瞬时网络问题）按 retries 重试，与 _run_rsync 行为一致。
    """
    quiet = _deploy_quiet()
    for attempt in range(1, retries + 1):
        cmd = ssh_cmd(remote_cmd, cfg=cfg)
        try:
            if quiet:
                r = subprocess.run(
                    cmd,
                    check=False,
                    cwd=PROJECT_ROOT,
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                )
                if r.returncode == 255 and check and attempt < retries:
                    print(
                        "%s SSH 失败（exit 255，第 %s/%s 次），3 秒后重试…"
                        % (du.I_WARN, attempt, retries),
                        file=sys.stderr,
                    )
                    time.sleep(3)
                    continue
                if check and r.returncode != 0:
                    if r.stdout:
                        sys.stdout.write(r.stdout)
                    if r.stderr:
                        sys.stderr.write(r.stderr)
                    raise subprocess.CalledProcessError(
                        r.returncode, cmd, r.stdout, r.stderr
                    )
                return
            subprocess.run(
                cmd,
                check=check,
                cwd=PROJECT_ROOT,
                stdin=subprocess.DEVNULL,
            )
            return
        except subprocess.CalledProcessError as e:
            if (
                not check
                or e.returncode != 255
                or attempt >= retries
            ):
                raise
            print(
                "%s SSH 失败（exit 255，第 %s/%s 次），3 秒后重试…"
                % (du.I_WARN, attempt, retries),
                file=sys.stderr,
            )
            time.sleep(3)


def _flutter_host_remove_sqlite(cfg: dict) -> None:
    """双机部署时 Flutter 静态机不应保留 baasapi/；同步或 pip 后删除遗留目录（check=False）。"""
    rp = cfg["remote_path"]
    _run_ssh_timed(
        "Flutter 静态：rm -rf baasapi/（双机不应同步后端）",
        "rm -rf %s" % shlex.quote(rp + "/baasapi"),
        cfg=cfg,
        check=False,
    )


def _rsync_deploy_exclude_patterns() -> list[str]:
    """AWS 部署 rsync 排除项：不上传 Dart/Gradle 源码、测试、IDE、本地密钥与仅开发用脚本。"""
    return [
        ".git",
        ".cursor",
        ".vscode",
        ".venv",
        ".gradle",
        ".idea",
        ".mypy_cache",
        ".pytest_cache",
        ".temp-cursor",
        ".DS_Store",
        "test",
        "app",
        "flutterapp",
        "gradle",
        "gradlew",
        "build.gradle.kts",
        "settings.gradle.kts",
        "gradle.properties",
        "local.properties",
        "README.md",
        "deploy2AWS.sh",
        "deploy2Local.sh",
        "*.iml",
        "__pycache__",
        "*.pyc",
        "*.log",
        # 本地部署配置（含本机 PEM 路径）；运行时不依赖
        "baasapi/deploy-aws.json",
        "baasapi/server_mgr.py",
        "baasapi/README-DEPLOY.md",
        "baasapi/test_server.sh",
        "baasapi/install_on_aws.sh",
        "baasapi/run_local.sh",
        "baasapi/run_apk_debug.sh",
        "baasapi/build_and_deploy.sh",
        "baasapi/seed_mock_account_data.py",
        "baasapi/seed_test_seasons.py",
        # 本地 SQLite 库体积大且不应覆盖远端生产库；远端由 init_db / 迁移维护
        "baasapi/sqlite/*.db",
        # 不落盘：静态资源目录、本仓库运维脚本（导入库/探测等仅在开发者机器使用）
        "res",
        "ops",
    ]


def _rsync_ssh_e(cfg: dict) -> str:
    """rsync -e 使用的 ssh 命令：与 ssh_cmd/run_ssh 共用传输选项。"""
    key = PROJECT_ROOT / cfg["key"]
    port = cfg.get("port", 22)
    parts: list[str] = [
        "ssh",
        "-i",
        str(key),
        "-p",
        str(port),
    ] + _ssh_transport_opts(cfg)
    return " ".join(shlex.quote(p) for p in parts)


def _run_rsync(cmd: list, retries: int = 3, *, label: str | None = None) -> None:
    """rsync 偶发 'Connection closed' / exit 255 时自动重试。

    HZTECH_DEPLOY_QUIET=1 时：开始前打印 label（若有），命令加 --stats，成功后打印统计块与耗时。
    """
    quiet = _deploy_quiet()
    for attempt in range(1, retries + 1):
        if quiet:
            cmd_run = _with_rsync_quiet_stats(cmd)
            disp = label
            if not disp and len(cmd) >= 2:
                disp = "→ %s" % cmd[-1]
            if disp:
                print("%s rsync 开始　%s" % (du.I_UPLOAD, disp), flush=True)
            t0 = time.time()
            r = subprocess.run(
                cmd_run,
                check=False,
                cwd=PROJECT_ROOT,
                capture_output=True,
                text=True,
            )
            if r.returncode == 0:
                elapsed = time.time() - t0
                print(
                    "%s rsync 结束　%.1fs%s"
                    % (
                        du.I_OK,
                        elapsed,
                        ("　｜　%s" % disp) if disp else "",
                    ),
                    flush=True,
                )
                _print_rsync_stats_block(r.stderr or "")
                return
            if attempt < retries:
                print(
                    "%s rsync 失败（第 %s/%s 次），5 秒后重试…"
                    % (du.I_WARN, attempt, retries),
                    file=sys.stderr,
                )
                time.sleep(5)
                continue
            if r.stdout:
                sys.stdout.write(r.stdout)
            if r.stderr:
                sys.stderr.write(r.stderr)
            raise subprocess.CalledProcessError(r.returncode, cmd_run)
        try:
            subprocess.run(cmd, check=True, cwd=PROJECT_ROOT)
            return
        except subprocess.CalledProcessError:
            if attempt < retries:
                print(
                    "%s rsync 失败（第 %s/%s 次），5 秒后重试…"
                    % (du.I_WARN, attempt, retries),
                    file=sys.stderr,
                )
                time.sleep(5)
            else:
                raise


def _rsync_flutterapp_web_static(cfg: dict, rsync_mirror: bool, phase_label: str) -> None:
    """同步 flutterapp/web_static/（静态站脚本与轻量 requirements）；单机与 Flutter 双机公用。"""
    if not (FLUTTER_WEB_STATIC_DIR / "serve_web_static.py").is_file():
        raise FileNotFoundError("缺少 flutterapp/web_static/serve_web_static.py")
    ssh_e = _rsync_ssh_e(cfg)
    remote_base = f"{cfg['user']}@{cfg['host']}:{cfg['remote_path']}"
    rp = cfg["remote_path"]
    dst = rp + "/flutterapp/web_static"
    run_ssh(f"mkdir -p {shlex.quote(dst)}", cfg=cfg)
    del_flags = ["--delete"] if rsync_mirror else []
    _run_rsync(
        ["rsync"]
        + _rsync_compress_flags()
        + del_flags
        + [
            "-e",
            ssh_e,
            str(FLUTTER_WEB_STATIC_DIR) + "/",
            remote_base + "/flutterapp/web_static/",
        ],
        label="%s（flutterapp/web_static）→ %s/flutterapp/web_static/"
        % (phase_label, remote_base),
    )


def _rsync_one(
    cfg: dict,
    extra_excludes: list | None,
    sync_flutter_web: bool,
    rsync_mirror: bool = True,
    *,
    phase_label: str = "项目根目录",
):
    """同步项目根到指定主机。extra_excludes 追加排除项；sync_flutter_web 为 True 时再同步 flutter build/web。

    rsync_mirror：True 时 rsync 带 --delete（远端与源目录镜像一致）；False 时不删除远端多余文件（慎用）。"""
    remote_base = f"{cfg['user']}@{cfg['host']}:{cfg['remote_path']}"
    ssh_e = _rsync_ssh_e(cfg)
    excludes: list[str] = []
    for pat in _rsync_deploy_exclude_patterns():
        excludes.extend(["--exclude", pat])
    if extra_excludes:
        for x in extra_excludes:
            excludes.extend(["--exclude", x])
    cmd = ["rsync"] + _rsync_compress_flags() + (["--delete"] if rsync_mirror else [])
    cmd.extend(excludes)
    cmd.extend(["-e", ssh_e])
    cmd.extend([str(PROJECT_ROOT) + "/", remote_base + "/"])
    _run_rsync(
        cmd,
        label="%s（项目根）→ %s/" % (phase_label, remote_base),
    )
    if not sync_flutter_web:
        return
    web_src = flutterapp / "build" / "web"
    if web_src.is_dir() and (web_src / "index.html").is_file():
        # 主 rsync 排除了整个 flutterapp/，远程无 flutterapp/build/，须先建目录再同步 web 产物
        remote_web_dir = f"{cfg['remote_path']}/flutterapp/build/web"
        run_ssh(f"mkdir -p {shlex.quote(remote_web_dir)}", cfg=cfg)
        remote_web = remote_base + "/flutterapp/build/web/"
        wcmd = ["rsync"] + _rsync_compress_flags() + (["--delete"] if rsync_mirror else [])
        wcmd.extend(["-e", ssh_e, str(web_src) + "/", remote_web])
        _run_rsync(
            wcmd,
            label="%s（Flutter Web）→ %s" % (phase_label, remote_web),
        )
    else:
        print(
            "%s 未找到 flutterapp/build/web/index.html，跳过 Web 同步；可先执行: python3 baasapi/server_mgr.py build-web"
            % du.I_WARN,
            file=sys.stderr,
        )
    _rsync_flutterapp_web_static(cfg, rsync_mirror, phase_label)


def _rsync_flutter_host_web_apk_only(cfg: dict, rsync_mirror: bool = True) -> None:
    """双机部署时 Flutter 静态机：仅同步 apk/、flutterapp/build/web/、flutterapp/web_static/。

    不同步 baasapi/；远端 rm 清理历史上误同步的 baasapi/。

    rsync_mirror 为 False 时 rsync 不带 --delete，仍执行 rm -rf baasapi 以符合「静态机无后端目录」策略。
    """
    ssh_e = _rsync_ssh_e(cfg)
    remote_base = f"{cfg['user']}@{cfg['host']}:{cfg['remote_path']}"
    rp = cfg["remote_path"]
    run_ssh(
        "mkdir -p %s %s %s && rm -rf %s"
        % (
            shlex.quote(rp + "/apk"),
            shlex.quote(rp + "/flutterapp/build/web"),
            shlex.quote(rp + "/flutterapp/web_static"),
            shlex.quote(rp + "/baasapi"),
        ),
        cfg=cfg,
    )
    del_flags = ["--delete"] if rsync_mirror else []
    _rsync_apk_dir_to_host(cfg, rsync_mirror, "Flutter 静态机")
    web_src = flutterapp / "build" / "web"
    if web_src.is_dir() and (web_src / "index.html").is_file():
        _run_rsync(
            ["rsync"]
            + _rsync_compress_flags()
            + del_flags
            + [
                "-e",
                ssh_e,
                str(web_src) + "/",
                remote_base + "/flutterapp/build/web/",
            ],
            label="Flutter 静态机｜本机 build/web/ → %s/flutterapp/build/web/"
            % remote_base,
        )
    else:
        print(
            "%s 未找到 flutterapp/build/web/index.html，跳过 Web 同步；可先执行: python3 baasapi/server_mgr.py build-web"
            % du.I_WARN,
            file=sys.stderr,
        )
    _rsync_flutterapp_web_static(cfg, rsync_mirror, "Flutter 静态机")
    _flutter_host_remove_sqlite(cfg)


def rsync_sync(exclude=None, rsync_mirror: bool = True):
    """同步到 AWS：单机为整包 + Flutter Web + flutterapp/web_static；双机时先 BaasAPI 主机（完整后端），
    再 Flutter 静态机（apk + flutterapp/build/web + flutterapp/web_static，不同步 baasapi/）。

    排除项见 _rsync_deploy_exclude_patterns（测试/IDE/Gradle/Dart 源码/本地部署脚本等）。
    rsync_mirror：见 _rsync_one。
    HZTECH_DEPLOY_APK_ONLY=1：只推 apk/hztech-app-release.apk；双机时 BaasAPI 与 Flutter 静态机各推一份。"""
    if _deploy_apk_only_enabled():
        if not _deploy_quiet():
            if split_dual_deploy():
                du.step(
                    du.I_PACKAGE,
                    "仅同步 APK（HZTECH_DEPLOY_APK_ONLY=1）→ BaasAPI %s + Flutter %s　｜　%s"
                    % (
                        target_config("baasapi").get("host", ""),
                        target_config("flutterapp").get("host", ""),
                        DEFAULT_APK_NAME_RELEASE,
                    ),
                )
            else:
                du.step(
                    du.I_PACKAGE,
                    "仅同步 APK（HZTECH_DEPLOY_APK_ONLY=1）→ %s　｜　%s"
                    % (
                        target_config("flutterapp").get("host", ""),
                        DEFAULT_APK_NAME_RELEASE,
                    ),
                )
        if split_dual_deploy():
            _rsync_release_apk_only_to_host(target_config("baasapi"))
        _rsync_release_apk_only_to_host(target_config("flutterapp"))
        return
    ex = list(exclude) if exclude else []
    if split_dual_deploy():
        c_api = target_config("baasapi")
        api_ex = ex + ["flutterapp", "apk"]
        _rsync_one(
            c_api,
            api_ex,
            sync_flutter_web=False,
            rsync_mirror=rsync_mirror,
            phase_label="BaasAPI 主机",
        )
        _rsync_apk_dir_to_host(c_api, rsync_mirror, "BaasAPI 主机")
        c_web = target_config("flutterapp")
        _rsync_flutter_host_web_apk_only(c_web, rsync_mirror=rsync_mirror)
    else:
        c_web = target_config("flutterapp")
        _rsync_one(
            c_web,
            ex,
            sync_flutter_web=True,
            rsync_mirror=rsync_mirror,
            phase_label="单机 / 同机",
        )


def _flutter_build_env():
    """为 Flutter 子进程准备环境，确保 ANDROID_HOME 已设置。"""
    env = dict(os.environ)
    if env.get("ANDROID_HOME") and Path(env["ANDROID_HOME"]).is_dir():
        return env
    # 常见 Android SDK 路径（macOS / Linux）
    for candidate in [
        Path.home() / "Library" / "Android" / "sdk",
        Path.home() / "Android" / "Sdk",
        Path("/opt/homebrew/share/android-commandlinetools"),   # Homebrew Apple Silicon
        Path("/usr/local/share/android-commandlinetools"),       # Homebrew Intel
    ]:
        if candidate.is_dir():
            env["ANDROID_HOME"] = str(candidate)
            return env
    return env


def _web_https_api_dart_define_args() -> list[str]:
    """deploy-aws.json 顶层 web_https_api_base_url：HTTPS 站点上 Web 客户端用，避免混合内容拦截。"""
    try:
        c = load_config()
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return []
    v = c.get("web_https_api_base_url")
    if not isinstance(v, str) or not v.strip():
        return []
    return ["--dart-define", "WEB_HTTPS_API_BASE_URL=%s" % v.strip()]


def _flutter_dart_define_args():
    """为 flutter build 追加 --dart-define / --dart-define-from-file（API 基址等）。

    环境变量（任选其一，优先 HZTECH_API_BASE_URL）：
    - HZTECH_API_BASE_URL：直接传入 --dart-define=API_BASE_URL=...
    - FLUTTER_DART_DEFINE_FILE：相对项目根或绝对路径，传入 --dart-define-from-file

    若均未设置且存在 flutterapp/dart_defines/production.json，则默认使用该文件（Release APK/Web
    与 AWS 线上 API 一致；与 prefs.dart 中非 Debug 默认基址对齐）。

    另追加 deploy-aws.json 的 web_https_api_base_url → WEB_HTTPS_API_BASE_URL（仅 Web 在 https 页生效）。
    """
    https_extra = _web_https_api_dart_define_args()
    args: list[str] = []
    url = os.environ.get("HZTECH_API_BASE_URL", "").strip()
    if url:
        args.extend(["--dart-define", "API_BASE_URL=%s" % url])
        args.extend(https_extra)
        return args
    f = os.environ.get("FLUTTER_DART_DEFINE_FILE", "").strip()
    if not f:
        default_file = flutterapp / "dart_defines" / "production.json"
        if default_file.is_file():
            args.extend(["--dart-define-from-file", str(default_file.resolve())])
        args.extend(https_extra)
        return args
    path = Path(f)
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    path = path.resolve()
    if not path.is_file():
        du.warn("FLUTTER_DART_DEFINE_FILE 不是有效文件，已忽略: %s" % path)
        return args
    args.extend(["--dart-define-from-file", str(path)])
    args.extend(https_extra)
    return args


def _find_flutter(env):
    """解析 flutter 可执行文件路径，避免 subprocess 因 PATH 未包含 flutter 而报 FileNotFoundError。"""
    path_str = env.get("PATH", "")
    found = shutil.which("flutter", path=path_str)
    if found:
        return found
    # 常见 Flutter 安装目录（macOS/Linux）
    flutter_root = os.environ.get("FLUTTER_ROOT", "").strip()
    candidates = [
        Path(flutter_root) if flutter_root else None,
        Path.home() / "flutter",
        Path.home() / "development" / "flutter",
        Path.home() / "Developer" / "flutter",
    ]
    for base in candidates:
        if not base or not base.is_dir():
            continue
        # SDK 目录下为 bin/flutter
        exe = base / "bin" / "flutter"
        if exe.is_file() and os.access(exe, os.X_OK):
            return str(exe)
    # Homebrew 等可能直接装在 PATH 目录，已在 which 中检查过；再试常见 bin 目录
    for bin_dir in [Path("/opt/homebrew/bin"), Path("/usr/local/bin")]:
        exe = bin_dir / "flutter"
        if exe.is_file() and os.access(exe, os.X_OK):
            return str(exe)
    return None


def _run_build_cmd(cmd: list[str], cwd: str, env: dict) -> bool:
    """执行 flutter / gradle 子进程：继承终端输出、不设超时（release 首次构建常需数分钟）。"""
    try:
        subprocess.run(
            cmd,
            check=True,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
        )
        return True
    except subprocess.CalledProcessError as e:
        du.err("命令失败（退出码 %s）: %s" % (e.returncode, " ".join(shlex.quote(x) for x in cmd)))
        return False
    except KeyboardInterrupt:
        print(
            "\n%s 构建被中断（Ctrl+C）。release 首次构建通常需 5–15 分钟（Gradle 下载依赖），"
            "请保持等待；完成后重试: python3 baasapi/server_mgr.py build" % du.I_STOP
        )
        raise


def build_apk_flutter():
    """使用 Flutter 编译 release APK，并复制到 apk/。"""
    if not flutterapp.is_dir():
        return False
    env = _flutter_build_env()
    if not env.get("ANDROID_HOME"):
        du.err("未找到 Android SDK。请设置 ANDROID_HOME 或安装 Android Studio（默认: ~/Library/Android/sdk）。")
        return False
    flutter_cmd = _find_flutter(env)
    if not flutter_cmd:
        du.err("未找到 Flutter。请将 flutter 加入 PATH，或设置 FLUTTER_ROOT（如 export FLUTTER_ROOT=$HOME/flutter）。")
        return False
    du.step(
        du.I_HAMMER,
        "Flutter 构建 APK（release）　｜　ANDROID_HOME=%s" % env["ANDROID_HOME"],
    )
    extra = _flutter_dart_define_args()
    if extra:
        du.step(du.I_CLIP, "dart-define: %s" % " ".join(extra))
    du.tip("首次 release 可能较慢（Gradle 拉依赖），请勿按 Ctrl+C 中断。")
    if not _run_build_cmd(
        [flutter_cmd, "build", "apk", "--release", *extra],
        str(flutterapp),
        env,
    ):
        return False
    apk = _flutter_built_apk_path(debug=False)
    if not apk:
        du.err("未找到 Flutter 生成的 app-release.apk。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME_RELEASE
    shutil.copy2(apk, dest)
    du.ok("APK 已复制到: %s" % dest)
    return True


def _flutter_built_apk_path(debug: bool) -> Path | None:
    """Flutter 构建后 APK 路径（flutter-apk/ 或 apk/debug|release/，随 SDK 版本可能不同）。"""
    name = "app-debug.apk" if debug else "app-release.apk"
    p = FLUTTER_APK_DIR / name
    if p.is_file():
        return p
    sub = "debug" if debug else "release"
    alt = flutterapp / "build" / "app" / "outputs" / "apk" / sub / name
    if alt.is_file():
        return alt
    return None


def build_apk_flutter_debug():
    """使用 Flutter 编译 debug APK，并复制到 apk/hztech-app-debug.apk。"""
    if not flutterapp.is_dir():
        return False
    env = _flutter_build_env()
    if not env.get("ANDROID_HOME"):
        du.err("未找到 Android SDK。请设置 ANDROID_HOME 或安装 Android Studio（默认: ~/Library/Android/sdk）。")
        return False
    flutter_cmd = _find_flutter(env)
    if not flutter_cmd:
        du.err("未找到 Flutter。请将 flutter 加入 PATH，或设置 FLUTTER_ROOT（如 export FLUTTER_ROOT=$HOME/flutter）。")
        return False
    du.step(du.I_HAMMER, "Flutter 构建 APK（debug）　｜　ANDROID_HOME=%s" % env["ANDROID_HOME"])
    extra = _flutter_dart_define_args()
    if extra:
        du.step(du.I_CLIP, "dart-define: %s" % " ".join(extra))
    if not _run_build_cmd(
        [flutter_cmd, "build", "apk", "--debug", *extra],
        str(flutterapp),
        env,
    ):
        return False
    apk = _flutter_built_apk_path(debug=True)
    if not apk:
        du.err("未找到 Flutter 生成的 app-debug.apk。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME_DEBUG
    shutil.copy2(apk, dest)
    du.ok("APK 已复制到: %s" % dest)
    return True


def build_ios_flutter() -> bool:
    """macOS + Xcode：flutter build ipa --release，并复制到项目根 ipa/。

    - 非 macOS：跳过（打印说明），返回 False。
    - 默认不编译 iOS；需编译请设置 HZTECH_SKIP_IOS_BUILD=0（或 false/no）。
    - 构建失败（签名等）时返回 False。在请求编译 iOS 时失败会使 run_build_mobile 返回 1。
    """
    if not _ios_build_requested():
        du.skip("已跳过 iOS 构建（默认；需要 IPA 请设置 HZTECH_SKIP_IOS_BUILD=0）")
        return False
    if sys.platform != "darwin":
        du.skip("非 macOS 无法执行 flutter build ipa；Android APK 仍正常构建")
        return False
    if not flutterapp.is_dir():
        return False
    env = dict(os.environ)
    flutter_cmd = _find_flutter(env)
    if not flutter_cmd:
        du.warn("未找到 Flutter，跳过 iOS 构建。")
        return False
    du.step(du.I_APPLE, "Flutter 构建 iOS IPA（release）…")
    extra = _flutter_dart_define_args()
    if extra:
        du.step(du.I_CLIP, "dart-define: %s" % " ".join(extra))
    du.tip("iOS 归档可能较慢，请勿中断。")
    if not _run_build_cmd(
        [flutter_cmd, "build", "ipa", "--release", *extra],
        str(flutterapp),
        env,
    ):
        du.err(
            "iOS IPA 构建失败（Xcode 签名、证书或 Pods 等）。"
            "若不需要 IPA，请将 HZTECH_SKIP_IOS_BUILD 设为 1；或在本机修复签名后重试。"
        )
        return False
    if not FLUTTER_IPA_DIR.is_dir():
        du.err("未找到 Flutter 输出目录 build/ios/ipa。")
        return False
    ipas = list(FLUTTER_IPA_DIR.glob("*.ipa"))
    ipas.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    if not ipas:
        du.err("未在 build/ios/ipa 下找到 .ipa 文件。")
        return False
    IPA_DIR.mkdir(parents=True, exist_ok=True)
    dest = IPA_DIR / DEFAULT_IPA_NAME
    shutil.copy2(ipas[0], dest)
    du.ok("IPA 已复制到: %s" % dest)
    return True


def build_web_flutter():
    """flutter build web；产物由 serve_web_static 或 CDN 托管，不再由 main.py 提供。"""
    if not flutterapp.is_dir():
        return False
    env = dict(os.environ)
    flutter_cmd = _find_flutter(env)
    if not flutter_cmd:
        du.warn("未找到 Flutter，跳过 Web 构建。")
        return False
    du.step(du.I_GLOBE, "Flutter 构建 Web（release）…")
    extra = _flutter_dart_define_args()
    if extra:
        du.step(du.I_CLIP, "dart-define: %s" % " ".join(extra))
    if not _run_build_cmd(
        # 关闭 Wasm 预检：flutter_secure_storage_web 等不兼容 Wasm，与当前 JS 产物无关，仅减少构建日志噪声。
        [flutter_cmd, "build", "web", "--release", "--no-wasm-dry-run", *extra],
        str(flutterapp),
        env,
    ):
        return False
    idx = flutterapp / "build" / "web" / "index.html"
    if not idx.is_file():
        du.err("未找到 flutterapp/build/web/index.html。")
        return False
    du.ok("Flutter Web 已生成: %s" % idx)
    return True


def run_build_mobile() -> int:
    """构建 Android release APK；iOS IPA 默认不构建（需 HZTECH_SKIP_IOS_BUILD=0 才打）。成功返回 0，失败返回 1。

    仅 Web（跳过 APK/iOS）：export HZTECH_SKIP_MOBILE_BUILD=1
    非 macOS：只校验 APK。
    """
    if os.environ.get("HZTECH_SKIP_MOBILE_BUILD", "").strip().lower() in (
        "1",
        "true",
        "yes",
    ):
        du.skip("已跳过移动端构建（HZTECH_SKIP_MOBILE_BUILD）；仅后续 build-web 等会执行")
        return 0
    apk_ok = build_apk()
    ios_skipped = not _ios_build_requested()
    ios_ok = build_ios_flutter()
    if not apk_ok:
        return 1
    if sys.platform == "darwin" and not ios_skipped and not ios_ok:
        return 1
    return 0


def build_apk():
    """优先 Flutter 构建，否则使用 Gradle 构建原生 debug APK。"""
    if build_apk_flutter():
        return True
    if not GRADLEW.is_file():
        du.warn("未找到 gradlew 或 flutterapp，跳过 APK 构建。")
        return False
    if not (PROJECT_ROOT / "app" / "build.gradle.kts").exists():
        du.warn("未找到 app/build.gradle.kts，跳过 APK 构建。")
        return False
    du.step(du.I_HAMMER, "Gradle 构建 APK（assembleDebug）…")
    if not _run_build_cmd(
        [str(GRADLEW), "assembleDebug", "-p", str(PROJECT_ROOT)],
        str(PROJECT_ROOT),
        dict(os.environ),
    ):
        return False
    apk_list = list(APK_DEBUG_DIR.glob("*.apk")) if APK_DEBUG_DIR.exists() else []
    if not apk_list:
        du.err("未找到生成的 APK 文件。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME_RELEASE
    shutil.copy2(apk_list[0], dest)
    du.ok("APK 已复制到: %s" % dest)
    return True


def build_apk_debug() -> bool:
    """优先 Flutter debug APK，否则 Gradle assembleDebug；产物 apk/hztech-app-debug.apk。"""
    if build_apk_flutter_debug():
        return True
    if not GRADLEW.is_file():
        du.warn("未找到 gradlew 或 flutterapp，跳过 APK 构建。")
        return False
    if not (PROJECT_ROOT / "app" / "build.gradle.kts").exists():
        du.warn("未找到 app/build.gradle.kts，跳过 APK 构建。")
        return False
    du.step(du.I_HAMMER, "Gradle 构建 APK（assembleDebug，debug 产物）…")
    if not _run_build_cmd(
        [str(GRADLEW), "assembleDebug", "-p", str(PROJECT_ROOT)],
        str(PROJECT_ROOT),
        dict(os.environ),
    ):
        return False
    apk_list = list(APK_DEBUG_DIR.glob("*.apk")) if APK_DEBUG_DIR.exists() else []
    if not apk_list:
        du.err("未找到生成的 APK 文件。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME_DEBUG
    shutil.copy2(apk_list[0], dest)
    du.ok("APK 已复制到: %s" % dest)
    return True


def run_build_mobile_debug() -> int:
    """仅构建 Android debug APK（不构建 iOS）。成功返回 0。"""
    if os.environ.get("HZTECH_SKIP_MOBILE_BUILD", "").strip().lower() in (
        "1",
        "true",
        "yes",
    ):
        du.skip("已跳过移动端构建（HZTECH_SKIP_MOBILE_BUILD）；仅后续 build-web 等会执行")
        return 0
    if build_apk_debug():
        return 0
    return 1


def _remote_pip_install_wanted() -> bool:
    """设为 HZTECH_SKIP_REMOTE_PIP=1 可在依赖已就绪时跳过 restart 内的 pip，加快部署。"""
    v = os.environ.get("HZTECH_SKIP_REMOTE_PIP", "").strip().lower()
    return v not in ("1", "true", "yes")


def _maybe_remote_pip_install(
    remote_path: str,
    cfg: Optional[dict],
    role_label: str,
    requirements_rel: str = "baasapi/requirements.txt",
) -> None:
    if not _remote_pip_install_wanted():
        if not _deploy_quiet():
            du.skip("跳过远端 pip（HZTECH_SKIP_REMOTE_PIP=1）：%s" % role_label)
        return
    if not _deploy_quiet():
        du.step(
            du.I_TIME,
            "远端 pip install（%s）— 拉取 PyPI 可能较慢，请耐心等待…" % role_label,
        )
    _run_ssh_timed(
        "远端 pip install（%s）" % role_label,
        _remote_install_requirements_sh(remote_path, requirements_rel),
        cfg=cfg,
    )


def _remote_install_requirements_sh(
    remote_path: str, requirements_rel: str = "baasapi/requirements.txt"
) -> str:
    """远程 shell：在无 python3 -m pip 的机器上优先用 pip3（如 yum/dnf 装的 python3-pip）。

    使用 PIP_NO_INPUT 避免 pip 等待确认；默认可见进度；HZTECH_DEPLOY_QUIET=1 时对 pip 加 -q。
    Amazon Linux 2023 / Debian 系等带 PEP 668 时，须 PIP_BREAK_SYSTEM_PACKAGES=1 否则 --user 也会失败。
    requirements_rel：相对项目根，如 baasapi/requirements.txt 或 flutterapp/web_static/requirements-web-static.txt。
    """
    pq = " -q" if _deploy_quiet() else ""
    rq = shlex.quote(requirements_rel)
    pre = (
        "test -f %s || { echo \"远端缺少 %s（请先 deploy/rsync 同步后再 pip-remote）\" >&2; exit 2; }; "
    ) % (rq, rq)
    pip3_or_mod = (
        "export PIP_NO_INPUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_BREAK_SYSTEM_PACKAGES=1;"
        "(command -v pip3 >/dev/null 2>&1 && "
        "pip3 install%s -r %s --user || "
        "(python3 -c \"import pip\" 2>/dev/null && "
        "python3 -m pip install%s -r %s --user) || "
        "(python3 -m ensurepip --user -q 2>/dev/null; "
        "python3 -m pip install%s -r %s --user))"
    ) % (pq, rq, pq, rq, pq, rq)
    return "cd %s && %s%s" % (shlex.quote(remote_path), pre, pip3_or_mod)


def _api_listen_port(cfg: dict) -> int:
    """BaasAPI 进程监听端口：baasapi_port / app_port。"""
    return int(cfg.get("baasapi_port", cfg.get("app_port", cfg.get("web_port", 9001))))


def run_verify_deploy() -> int:
    """HTTP 探测 BaasAPI /api/health 与 Flutter Web /（503 视为 Web 未构建但可达）。返回 0 全部成功。"""
    import urllib.error
    import urllib.request

    rows: list[tuple[str, str, int, bool]] = []

    def _one(url: str, label: str) -> bool:
        try:
            with urllib.request.urlopen(url, timeout=15) as r:
                code = r.status
        except urllib.error.HTTPError as e:
            code = e.code
        except OSError:
            code = 0
        ok = code in (200, 503)
        rows.append((label, url, code, ok))
        if not _deploy_quiet():
            mark = du.I_OK if ok else du.I_WARN
            print("  %s %s → HTTP %s　%s" % (mark, label, code, url))
        return ok

    c = load_config()
    scheme = str(c.get("scheme") or "http")
    web_port = int(c.get("flutterapp_port", c.get("web_port", 9000)))
    api_port = _api_listen_port(c)
    fa = c.get("flutterapp") if isinstance(c.get("flutterapp"), dict) else {}
    ba = c.get("baasapi") if isinstance(c.get("baasapi"), dict) else {}
    if not fa:
        fa = c.get("web") if isinstance(c.get("web"), dict) else {}
    if not ba:
        ba = c.get("api") if isinstance(c.get("api"), dict) else {}
    dual = isinstance(fa, dict) and isinstance(ba, dict)
    wh = (fa.get("host") or c.get("host") or "").strip()
    ah = (ba.get("host") or "").strip()
    if not dual and not ah:
        ah = wh
    ok = True
    if dual:
        ok = _one("%s://%s:%s/api/health" % (scheme, ah, api_port), "BaasAPI 健康检查") and ok
        ok = _one("%s://%s:%s/" % (scheme, wh, web_port), "Flutter 静态站首页") and ok
    else:
        ok = _one("%s://%s:%s/api/health" % (scheme, wh, api_port), "BaasAPI 健康检查") and ok
        ok = _one("%s://%s:%s/" % (scheme, wh, web_port), "Flutter 静态站首页") and ok
    if _deploy_quiet():
        if ok:
            print("%s 部署后健康检查通过（API + Web 可达）" % du.I_OK)
        else:
            for label, url, code, row_ok in rows:
                mark = du.I_OK if row_ok else du.I_WARN
                print("  %s %s → HTTP %s　%s" % (mark, label, code, url))
            print("%s 健康检查未全部通过" % du.I_WARN)
    return 0 if ok else 1


def remote_restart_api():
    """在 BaasAPI 主机上启动完整后端（/api/*、/kline、/download 等 + DB + 定时任务）。"""
    c = target_config("baasapi")
    remote_path = c["remote_path"]
    api_port = _api_listen_port(c)
    host = c["host"]
    if not _deploy_quiet():
        du.step(du.I_REFRESH, "重启 BaasAPI　｜　主机 %s　端口 %s" % (host, api_port))
    start_main = (
        f"cd {remote_path} && {_remote_baasapi_start_env(remote_path, api_port)}"
        f"nohup python3 baasapi/main.py >> server.log 2>&1 & sleep 1"
    )
    if _remote_pip_install_wanted():
        _run_ssh_timed(
            "BaasAPI：pkill+mkdir（合并 SSH）",
            f"cd {remote_path} && pkill -f baasapi/main.py 2>/dev/null || true; "
            f"mkdir -p apk baasapi/sqlite",
            check=False,
            cfg=c,
        )
        _maybe_remote_pip_install(
            remote_path, c, "BaasAPI 主机", "baasapi/requirements.txt"
        )
        _run_ssh_timed("BaasAPI：nohup main.py", start_main, cfg=c)
    else:
        _run_ssh_timed(
            "BaasAPI：pkill+mkdir+启动（合并 SSH）",
            f"cd {remote_path} && pkill -f baasapi/main.py 2>/dev/null || true; "
            f"mkdir -p apk baasapi/sqlite; "
            f"{_remote_baasapi_start_env(remote_path, api_port)}"
            f"nohup python3 baasapi/main.py >> server.log 2>&1 & sleep 1",
            check=False,
            cfg=c,
        )
    if not _deploy_quiet():
        du.ok("BaasAPI 已启动　｜　日志 %s/server.log" % remote_path)


def remote_restart_web():
    """在 FlutterApp 主机上启动 Flutter Web 静态站（serve_web_static.py）；BaasAPI 在另一台机器时。"""
    c = target_config("flutterapp")
    remote_path = c["remote_path"]
    web_port = int(c.get("web_port", 9000))
    host = c["host"]
    web_root = f"{remote_path}/flutterapp/build/web"
    wrq = shlex.quote(web_root)
    if not _deploy_quiet():
        du.step(
            du.I_REFRESH,
            "重启 Flutter 静态站　｜　主机 %s　端口 %s　根目录 %s" % (host, web_port, web_root),
        )
    prep = (
        f"cd {remote_path} && "
        f"pkill -f baasapi/serve_web_static.py 2>/dev/null || true; "
        f"pkill -f flutterapp/web_static/serve_web_static.py 2>/dev/null || true; "
        f"rm -rf baasapi && mkdir -p apk res flutterapp/web_static"
    )
    start_body = (
        f"HZTECH_WEB_ROOT={wrq} PORT={web_port} "
        f"nohup python3 flutterapp/web_static/serve_web_static.py >> web_static.log 2>&1 & sleep 1"
    )
    if _remote_pip_install_wanted():
        _run_ssh_timed("Flutter 静态：停服务+清目录（合并 SSH）", prep, check=False, cfg=c)
        _maybe_remote_pip_install(
            remote_path, c, "Flutter 静态主机", FLUTTER_WEB_STATIC_REQ_REL
        )
        _run_ssh_timed(
            "Flutter 静态：pip 后再清 baasapi 遗留 + 启动（合并 SSH）",
            f"cd {remote_path} && rm -rf baasapi && {start_body}",
            cfg=c,
        )
    else:
        _run_ssh_timed(
            "Flutter 静态：停服务+清目录+启动（合并 SSH）",
            f"{prep}; {start_body}",
            check=False,
            cfg=c,
        )
    if not _deploy_quiet():
        du.ok("Flutter 静态站已启动　｜　日志 %s/web_static.log" % remote_path)


def remote_restart_single():
    """单主机部署：BaasAPI（main.py）+ FlutterApp 静态（serve_web_static.py）双进程。"""
    c = target_config("flutterapp")
    remote_path = c["remote_path"]
    web_port = int(c.get("web_port", 9000))
    api_port = _api_listen_port(c)
    web_root = f"{remote_path}/flutterapp/build/web"
    wrq = shlex.quote(web_root)
    if not _deploy_quiet():
        du.step(
            du.I_REFRESH,
            "重启 API + 静态站（同机）　｜　%s　API:%s　Web:%s" % (c["host"], api_port, web_port),
        )
    start_api = (
        f"{_remote_baasapi_start_env(remote_path, api_port)}"
        f"nohup python3 baasapi/main.py >> server.log 2>&1 & "
    )
    start_web = (
        f"HZTECH_WEB_ROOT={wrq} PORT={web_port} "
        f"nohup python3 flutterapp/web_static/serve_web_static.py >> web_static.log 2>&1 & "
    )
    if _remote_pip_install_wanted():
        _run_ssh_timed(
            "同机：双 pkill+mkdir（合并 SSH）",
            "cd %s && pkill -f baasapi/main.py 2>/dev/null || true; "
            "pkill -f baasapi/serve_web_static.py 2>/dev/null || true; "
            "pkill -f flutterapp/web_static/serve_web_static.py 2>/dev/null || true; "
            "mkdir -p apk res baasapi/sqlite flutterapp/web_static" % remote_path,
            check=False,
            cfg=c,
        )
        _maybe_remote_pip_install(remote_path, None, "API+Web 主机", "baasapi/requirements.txt")
        _run_ssh_timed(
            "同机：双进程启动（合并 SSH）",
            f"cd {remote_path} && {start_api}{start_web}sleep 1",
            cfg=c,
        )
    else:
        _run_ssh_timed(
            "同机：准备+双进程启动（合并 SSH）",
            f"cd {remote_path} && pkill -f baasapi/main.py 2>/dev/null || true; "
            f"pkill -f baasapi/serve_web_static.py 2>/dev/null || true; "
            f"pkill -f flutterapp/web_static/serve_web_static.py 2>/dev/null || true; "
            f"mkdir -p apk res baasapi/sqlite flutterapp/web_static; {start_api}{start_web}sleep 1",
            check=False,
            cfg=c,
        )
    if not _deploy_quiet():
        du.ok(
            "同机双进程已启动　｜　API:%s → server.log　Web:%s → web_static.log　根:%s"
            % (api_port, web_port, web_root)
        )


def remote_restart():
    """分两台时先 API 后 Web；单机或同机两段配置时尽量合并远程命令为单次 SSH。

    编排器 AWS 阶段 8 通常传 HZTECH_SKIP_REMOTE_PIP=1：每台机 1 次 SSH 即可完成停服务+目录+启动；
    若需远端 pip 则多一次 SSH。主要耗时仍为 SSH 握手与脚本内 sleep 1。
    """
    if split_dual_deploy():
        remote_restart_api()
        remote_restart_web()
    else:
        remote_restart_single()


def remote_pip_install_only():
    """仅在远端执行 pip install -r requirements（真双机：BaasAPI 全量依赖 + Flutter 机仅 Flask）。

    Flutter 静态机主 rsync 不包含 flutterapp/，故 pip-remote 前会自动同步 flutterapp/web_static/，
    避免远端缺少 requirements-web-static.txt 时必须先手跑 deploy。
    """
    if split_dual_deploy():
        c_api = target_config("baasapi")
        c_web = target_config("flutterapp")
        if not _deploy_quiet():
            du.step(du.I_TIME, "远端 pip　｜　BaasAPI 主机 %s" % c_api["host"])
        run_ssh(
            _remote_install_requirements_sh(
                c_api["remote_path"], "baasapi/requirements.txt"
            ),
            cfg=c_api,
        )
        if not _deploy_quiet():
            du.step(du.I_TIME, "pip-remote：同步 flutterapp/web_static → %s" % c_web["host"])
        _rsync_flutterapp_web_static(c_web, rsync_mirror=False, phase_label="pip-remote")
        if not _deploy_quiet():
            du.step(du.I_TIME, "远端 pip　｜　Flutter 静态主机 %s" % c_web["host"])
        run_ssh(
            _remote_install_requirements_sh(
                c_web["remote_path"], FLUTTER_WEB_STATIC_REQ_REL
            ),
            cfg=c_web,
        )
        _flutter_host_remove_sqlite(c_web)
    else:
        rp = get_remote_path()
        if not _deploy_quiet():
            du.step(du.I_TIME, "远端 pip　｜　%s" % target_config("flutterapp")["host"])
        run_ssh(_remote_install_requirements_sh(rp, "baasapi/requirements.txt"))
    if not _deploy_quiet():
        du.ok("远端 Python 依赖安装完成")


def deploy_and_start(port=None, start_server=True, rsync_mirror: bool = True):
    """同步到 AWS；可选在远程安装依赖并启动服务。"""
    c = load_config()
    cweb = target_config("flutterapp")
    if port is None:
        port = int(c.get("flutterapp_port", c.get("web_port", 9000)))
    if not _deploy_quiet():
        if _deploy_apk_only_enabled():
            if split_dual_deploy():
                capi = target_config("baasapi")
                du.step(
                    du.I_UPLOAD,
                    "同步 APK → BaasAPI %s + Flutter %s:%s　｜　%s"
                    % (
                        capi["host"],
                        cweb["host"],
                        cweb["remote_path"],
                        DEFAULT_APK_NAME_RELEASE,
                    ),
                )
            else:
                du.step(
                    du.I_UPLOAD,
                    "同步 APK → %s:%s　｜　%s"
                    % (cweb["host"], cweb["remote_path"], DEFAULT_APK_NAME_RELEASE),
                )
        elif split_dual_deploy():
            capi = target_config("baasapi")
            flutter_tail = (
                "；再 Web（跳过 APK 同步）→ Flutter %s:%s"
                if _deploy_skip_apk_sync()
                else "；再 Web+APK → Flutter %s:%s"
            ) % (cweb["host"], cweb["remote_path"])
            du.step(
                du.I_UPLOAD,
                "全量同步（双机）→ BaasAPI %s:%s%s"
                % (capi["host"], capi["remote_path"], flutter_tail),
            )
        elif has_dual_deploy() and _deploy_same_remote_target():
            du.step(
                du.I_UPLOAD,
                "全量同步（同机同目录）→ %s:%s（含 flutterapp/build/web）"
                % (cweb["host"], cweb["remote_path"]),
            )
        else:
            du.step(
                du.I_UPLOAD,
                "同步项目 → %s:%s …" % (cweb["host"], cweb["remote_path"]),
            )
    rsync_sync(rsync_mirror=rsync_mirror)
    if not start_server:
        if not _deploy_quiet():
            du.ok("同步完成；已跳过启动。手动重启: python3 baasapi/server_mgr.py restart")
        return
    remote_restart()
    web_port = int(c.get("flutterapp_port", c.get("web_port", 9000)))
    api_port = _api_listen_port(c)
    rp = get_remote_path()
    scheme = c.get("scheme", "http")
    if not _deploy_quiet():
        du.hr()
        if split_dual_deploy():
            capi = target_config("baasapi")
            du.ok(
                "部署完成　｜　BaasAPI %s://%s:%s/api/　｜　Flutter %s://%s:%s/"
                % (scheme, capi["host"], api_port, scheme, cweb["host"], web_port)
            )
            du.tip(
                "日志：API 机 %s/server.log　｜　静态机 %s/web_static.log"
                % (capi["remote_path"], rp)
            )
        else:
            du.ok(
                "部署完成　｜　BaasAPI %s://%s:%s/api/　｜　Flutter %s://%s:%s/"
                % (scheme, cweb["host"], api_port, scheme, cweb["host"], web_port)
            )
            du.tip("日志：%s/server.log 与 %s/web_static.log" % (rp, rp))


if __name__ == "__main__":
    cfg = load_config()
    if len(sys.argv) > 1 and sys.argv[1] == "build":
        sys.exit(run_build_mobile())
    if len(sys.argv) > 1 and sys.argv[1] == "build-debug":
        sys.exit(run_build_mobile_debug())
    if len(sys.argv) > 1 and sys.argv[1] == "build-ios":
        ok = build_ios_flutter()
        sys.exit(0 if ok else 1)
    if len(sys.argv) > 1 and sys.argv[1] == "build-web":
        ok = build_web_flutter()
        sys.exit(0 if ok else 1)
    if len(sys.argv) > 1 and sys.argv[1] == "deploy":
        start = "--no-start" not in sys.argv
        do_build = "--build" in sys.argv
        rsync_mirror = "--rsync-no-delete" not in sys.argv
        if do_build:
            rc = run_build_mobile()
            if rc != 0:
                sys.exit(rc)
        if "--build-web" in sys.argv:
            build_web_flutter()
        deploy_and_start(
            port=int(cfg.get("flutterapp_port", cfg.get("web_port", cfg.get("port", 9000)))),
            start_server=start,
            rsync_mirror=rsync_mirror,
        )
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "verify":
        sys.exit(run_verify_deploy())
    if len(sys.argv) > 1 and sys.argv[1] == "restart":
        remote_restart()
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "restart-web":
        remote_restart_web()
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "pip-remote":
        remote_pip_install_only()
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "db-sync":
        if has_dual_deploy():
            c_api = target_config("baasapi")
            remote_path = c_api["remote_path"]
            run_ssh(
                f"cd {remote_path} && python3 -c 'from baasapi.db import init_db; init_db()'",
                cfg=c_api,
            )
            if not _deploy_quiet():
                du.ok("数据库迁移已在 API 主机执行完成　｜　%s" % c_api["host"])
        else:
            remote_path = get_remote_path()
            run_ssh(f"cd {remote_path} && python3 -c 'from baasapi.db import init_db; init_db()'")
            if not _deploy_quiet():
                du.ok("数据库迁移已在远端执行完成")
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "shell":
        subprocess.run(ssh_cmd(), cwd=PROJECT_ROOT)
        sys.exit(0)
    print("Config:", json.dumps(cfg, indent=2, ensure_ascii=False))
    target, key = get_ssh_target()
    print("SSH target:", target, "key:", key)
    print(
        "Usage: python server_mgr.py [build | build-debug | build-ios | build-web | deploy [--build] [--build-web] [--no-start] [--rsync-no-delete] | restart | restart-web | pip-remote | db-sync | verify | shell]"
    )
