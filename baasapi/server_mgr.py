"""AWS 部署配置与 SSH 管理。从 baasapi/deploy-aws.json 读取配置；盘符目录为 baasapi/、flutterapp/，
配置段键名仍为 flutterapp / baasapi（ports：flutterapp_port、baasapi_port）。兼容旧键 web / api。

双机部署（同时配置 flutterapp 与 baasapi 段）：BaasAPI 主机同步完整后端（含数据库目录）；Flutter 主机
仅同步 APK、Flutter Web 产物与静态站所需的最小 baasapi 文件，不部署、不创建、并清理遗留的 sqlite/。"""
from pathlib import Path
import json
import os
import shlex
import shutil
import subprocess
import sys
import time

# 项目根目录（baasapi 的上一级）
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DEPLOY_CONFIG_PATH = PROJECT_ROOT / "baasapi" / "deploy-aws.json"
# 兼容旧名（仅文档/外部引用）
CONFIG_PATH = DEFAULT_DEPLOY_CONFIG_PATH
GRADLEW = PROJECT_ROOT / "gradlew"
flutterapp = PROJECT_ROOT / "flutterapp"
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
    """与 deploy2AWS.sh 一致：双机取 baasapi 段 host，单机补齐 host；用于未设置 HZTECH_API_BASE_URL 时。"""
    c = load_config()
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


def _deploy_apk_only_enabled() -> bool:
    v = os.environ.get("HZTECH_DEPLOY_APK_ONLY", "").strip().lower()
    return v in ("1", "true", "yes")


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
        [
            "rsync",
            "-avz",
            "-e",
            ssh_e,
            str(apk_path),
            remote_base + "/apk/" + apk_path.name,
        ]
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


def run_ssh(remote_cmd, check=True, cfg=None, retries: int = 3):
    """在 AWS 上执行单条命令。check=False 时忽略非零退出码（如 pkill 无匹配）。

    对 SSH 退出码 255（连接被关闭、瞬时网络问题）按 retries 重试，与 _run_rsync 行为一致。
    """
    for attempt in range(1, retries + 1):
        try:
            subprocess.run(ssh_cmd(remote_cmd, cfg=cfg), check=check, cwd=PROJECT_ROOT)
            return
        except subprocess.CalledProcessError as e:
            if (
                not check
                or e.returncode != 255
                or attempt >= retries
            ):
                raise
            print(
                "ssh 失败 exit 255（第 %s/%s 次），3 秒后重试…"
                % (attempt, retries),
                file=sys.stderr,
            )
            time.sleep(3)


def _flutter_host_remove_sqlite(cfg: dict) -> None:
    """双机部署时 Flutter 静态机不应存在 baasapi/sqlite；同步或 pip 后若存在则删除（check=False）。"""
    rp = cfg["remote_path"]
    run_ssh("rm -rf %s" % shlex.quote(rp + "/baasapi/sqlite"), cfg=cfg, check=False)


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


def _run_rsync(cmd: list, retries: int = 3) -> None:
    """rsync 偶发 'Connection closed' / exit 255 时自动重试。"""
    for attempt in range(1, retries + 1):
        try:
            subprocess.run(cmd, check=True, cwd=PROJECT_ROOT)
            return
        except subprocess.CalledProcessError:
            if attempt < retries:
                print(
                    "rsync failed (attempt %s/%s), retrying in 5s..."
                    % (attempt, retries),
                    file=sys.stderr,
                )
                time.sleep(5)
            else:
                raise


def _rsync_one(
    cfg: dict, extra_excludes: list | None, sync_flutter_web: bool, rsync_mirror: bool = True
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
    cmd = ["rsync", "-avz"] + (["--delete"] if rsync_mirror else [])
    cmd.extend(excludes)
    cmd.extend(["-e", ssh_e])
    cmd.extend([str(PROJECT_ROOT) + "/", remote_base + "/"])
    _run_rsync(cmd)
    if not sync_flutter_web:
        return
    web_src = flutterapp / "build" / "web"
    if web_src.is_dir() and (web_src / "index.html").is_file():
        # 主 rsync 排除了整个 flutterapp/，远程无 flutterapp/build/，须先建目录再同步 web 产物
        remote_web_dir = f"{cfg['remote_path']}/flutterapp/build/web"
        run_ssh(f"mkdir -p {shlex.quote(remote_web_dir)}", cfg=cfg)
        remote_web = remote_base + "/flutterapp/build/web/"
        wcmd = ["rsync", "-avz"] + (["--delete"] if rsync_mirror else [])
        wcmd.extend(["-e", ssh_e, str(web_src) + "/", remote_web])
        _run_rsync(wcmd)


def _rsync_flutter_host_web_apk_only(cfg: dict, rsync_mirror: bool = True) -> None:
    """双机部署时 Flutter 主机：仅同步 apk/、flutterapp/build/web/、baasapi/serve_web_static.py 与 requirements.txt。

    不推送完整 baasapi 源码；不部署数据库目录，并在同步末尾删除远端 baasapi/sqlite/（若有遗留）。

    rsync_mirror 为 False 时不执行远端 rm -rf baasapi，且 rsync 不带 --delete。
    """
    ssh_e = _rsync_ssh_e(cfg)
    remote_base = f"{cfg['user']}@{cfg['host']}:{cfg['remote_path']}"
    rp = cfg["remote_path"]
    if rsync_mirror:
        # 清空远端 baasapi/，避免历史上整包同步留下的 main.py、sqlite 等与 API 主机混淆
        run_ssh(
            "mkdir -p %s %s && rm -rf %s && mkdir -p %s"
            % (
                shlex.quote(rp + "/apk"),
                shlex.quote(rp + "/flutterapp/build/web"),
                shlex.quote(rp + "/baasapi"),
                shlex.quote(rp + "/baasapi"),
            ),
            cfg=cfg,
        )
    else:
        run_ssh(
            "mkdir -p %s %s %s"
            % (
                shlex.quote(rp + "/apk"),
                shlex.quote(rp + "/flutterapp/build/web"),
                shlex.quote(rp + "/baasapi"),
            ),
            cfg=cfg,
        )
    del_flags = ["--delete"] if rsync_mirror else []
    apk_src = PROJECT_ROOT / "apk"
    if apk_src.is_dir():
        _run_rsync(
            ["rsync", "-avz"] + del_flags + ["-e", ssh_e, str(apk_src) + "/", remote_base + "/apk/"]
        )
    web_src = flutterapp / "build" / "web"
    if web_src.is_dir() and (web_src / "index.html").is_file():
        _run_rsync(
            [
                "rsync",
                "-avz",
            ]
            + del_flags
            + [
                "-e",
                ssh_e,
                str(web_src) + "/",
                remote_base + "/flutterapp/build/web/",
            ]
        )
    else:
        print(
            "提示: 未找到 flutterapp/build/web/index.html，跳过 Web 同步；"
            "可先执行: python baasapi/server_mgr.py build-web",
            file=sys.stderr,
        )
    for name in ("serve_web_static.py", "requirements.txt"):
        src = PROJECT_ROOT / "baasapi" / name
        if not src.is_file():
            raise FileNotFoundError("缺少部署文件: %s" % src)
        _run_rsync(["rsync", "-avz", "-e", ssh_e, str(src), remote_base + "/baasapi/"])
    _flutter_host_remove_sqlite(cfg)


def rsync_sync(exclude=None, rsync_mirror: bool = True):
    """同步到 AWS：单机为整包 + Flutter Web；双机时先 BaasAPI 主机（完整后端），再 Flutter 主机（仅 Web+APK+最小静态脚本）。

    排除项见 _rsync_deploy_exclude_patterns（测试/IDE/Gradle/Dart 源码/本地部署脚本等）。
    rsync_mirror：见 _rsync_one。"""
    if _deploy_apk_only_enabled():
        print(
            "HZTECH_DEPLOY_APK_ONLY=1：仅上传 %s（双机时 API 与 Flutter 各推一份，便于 /download/apk）"
            % DEFAULT_APK_NAME_RELEASE
        )
        if has_dual_deploy():
            _rsync_release_apk_only_to_host(target_config("baasapi"))
            _rsync_release_apk_only_to_host(target_config("flutterapp"))
        else:
            _rsync_release_apk_only_to_host(target_config("flutterapp"))
        return
    ex = list(exclude) if exclude else []
    if has_dual_deploy():
        c_api = target_config("baasapi")
        api_ex = ex + ["flutterapp", "apk"]
        _rsync_one(c_api, api_ex, sync_flutter_web=False, rsync_mirror=rsync_mirror)
        c_web = target_config("flutterapp")
        _rsync_flutter_host_web_apk_only(c_web, rsync_mirror=rsync_mirror)
    else:
        c_web = target_config("flutterapp")
        _rsync_one(c_web, ex, sync_flutter_web=True, rsync_mirror=rsync_mirror)


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


def _flutter_dart_define_args():
    """为 flutter build 追加 --dart-define / --dart-define-from-file（API 基址等）。

    环境变量（任选其一，优先 HZTECH_API_BASE_URL）：
    - HZTECH_API_BASE_URL：直接传入 --dart-define=API_BASE_URL=...
    - FLUTTER_DART_DEFINE_FILE：相对项目根或绝对路径，传入 --dart-define-from-file

    若均未设置且存在 flutterapp/dart_defines/production.json，则默认使用该文件（Release APK/Web
    与 AWS 线上 API 一致；与 prefs.dart 中非 Debug 默认基址对齐）。
    """
    args: list[str] = []
    url = os.environ.get("HZTECH_API_BASE_URL", "").strip()
    if url:
        args.extend(["--dart-define", "API_BASE_URL=%s" % url])
        return args
    f = os.environ.get("FLUTTER_DART_DEFINE_FILE", "").strip()
    if not f:
        default_file = flutterapp / "dart_defines" / "production.json"
        if default_file.is_file():
            args.extend(["--dart-define-from-file", str(default_file.resolve())])
        return args
    path = Path(f)
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    path = path.resolve()
    if not path.is_file():
        print("警告: FLUTTER_DART_DEFINE_FILE 不是有效文件，已忽略: %s" % path)
        return args
    args.extend(["--dart-define-from-file", str(path)])
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
        print("命令失败（退出码 %s）: %s" % (e.returncode, " ".join(shlex.quote(x) for x in cmd)))
        return False
    except KeyboardInterrupt:
        print(
            "\n构建被中断（Ctrl+C）。release 首次构建通常需 5–15 分钟（Gradle 下载依赖），"
            "请保持等待；完成后重试: python server_mgr.py build"
        )
        raise


def build_apk_flutter():
    """使用 Flutter 编译 release APK，并复制到 apk/。"""
    if not flutterapp.is_dir():
        return False
    env = _flutter_build_env()
    if not env.get("ANDROID_HOME"):
        print("未找到 Android SDK。请设置 ANDROID_HOME 或安装 Android Studio（默认: ~/Library/Android/sdk）。")
        return False
    flutter_cmd = _find_flutter(env)
    if not flutter_cmd:
        print("未找到 Flutter。请将 flutter 加入 PATH，或设置 FLUTTER_ROOT（如 export FLUTTER_ROOT=$HOME/flutter）。")
        return False
    print("Building Flutter APK (release) ... (ANDROID_HOME=%s)" % env["ANDROID_HOME"])
    extra = _flutter_dart_define_args()
    if extra:
        print("  dart-define: %s" % " ".join(extra))
    print(
        "（提示：首次 release 构建可能较慢，Gradle 会解析依赖；请勿按 Ctrl+C 中断。）"
    )
    if not _run_build_cmd(
        [flutter_cmd, "build", "apk", "--release", *extra],
        str(flutterapp),
        env,
    ):
        return False
    apk = _flutter_built_apk_path(debug=False)
    if not apk:
        print("未找到 Flutter 生成的 app-release.apk。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME_RELEASE
    shutil.copy2(apk, dest)
    print("APK 已复制到: %s" % dest)
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
        print("未找到 Android SDK。请设置 ANDROID_HOME 或安装 Android Studio（默认: ~/Library/Android/sdk）。")
        return False
    flutter_cmd = _find_flutter(env)
    if not flutter_cmd:
        print("未找到 Flutter。请将 flutter 加入 PATH，或设置 FLUTTER_ROOT（如 export FLUTTER_ROOT=$HOME/flutter）。")
        return False
    print("Building Flutter APK (debug) ... (ANDROID_HOME=%s)" % env["ANDROID_HOME"])
    extra = _flutter_dart_define_args()
    if extra:
        print("  dart-define: %s" % " ".join(extra))
    if not _run_build_cmd(
        [flutter_cmd, "build", "apk", "--debug", *extra],
        str(flutterapp),
        env,
    ):
        return False
    apk = _flutter_built_apk_path(debug=True)
    if not apk:
        print("未找到 Flutter 生成的 app-debug.apk。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME_DEBUG
    shutil.copy2(apk, dest)
    print("APK 已复制到: %s" % dest)
    return True


def build_ios_flutter() -> bool:
    """macOS + Xcode：flutter build ipa --release，并复制到项目根 ipa/。

    - 非 macOS：跳过（打印说明），返回 False。
    - 默认不编译 iOS；需编译请设置 HZTECH_SKIP_IOS_BUILD=0（或 false/no）。
    - 构建失败（签名等）时返回 False。在请求编译 iOS 时失败会使 run_build_mobile 返回 1。
    """
    if not _ios_build_requested():
        print(
            "已跳过 iOS 构建（默认；需要 IPA 请设置 HZTECH_SKIP_IOS_BUILD=0）。"
        )
        return False
    if sys.platform != "darwin":
        print("跳过 iOS 构建（非 macOS 无法执行 flutter build ipa；Android APK 仍正常构建）。")
        return False
    if not flutterapp.is_dir():
        return False
    env = dict(os.environ)
    flutter_cmd = _find_flutter(env)
    if not flutter_cmd:
        print("未找到 Flutter，跳过 iOS 构建。")
        return False
    print("Building Flutter iOS IPA (release) ...")
    extra = _flutter_dart_define_args()
    if extra:
        print("  dart-define: %s" % " ".join(extra))
    print("（提示：iOS 归档可能较慢，请勿中断。）")
    if not _run_build_cmd(
        [flutter_cmd, "build", "ipa", "--release", *extra],
        str(flutterapp),
        env,
    ):
        print(
            "iOS IPA 构建失败（Xcode 签名、证书或 Pods 等）。"
            "若不需要 IPA，请 unset HZTECH_SKIP_IOS_BUILD 或设为 1；或在本机修复签名后重试。"
        )
        return False
    if not FLUTTER_IPA_DIR.is_dir():
        print("未找到 Flutter 输出目录 build/ios/ipa。")
        return False
    ipas = list(FLUTTER_IPA_DIR.glob("*.ipa"))
    ipas.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    if not ipas:
        print("未在 build/ios/ipa 下找到 .ipa 文件。")
        return False
    IPA_DIR.mkdir(parents=True, exist_ok=True)
    dest = IPA_DIR / DEFAULT_IPA_NAME
    shutil.copy2(ipas[0], dest)
    print("IPA 已复制到: %s" % dest)
    return True


def build_web_flutter():
    """flutter build web；产物由 serve_web_static 或 CDN 托管，不再由 main.py 提供。"""
    if not flutterapp.is_dir():
        return False
    env = dict(os.environ)
    flutter_cmd = _find_flutter(env)
    if not flutter_cmd:
        print("未找到 Flutter，跳过 Web 构建。")
        return False
    print("Building Flutter Web (release) ...")
    extra = _flutter_dart_define_args()
    if extra:
        print("  dart-define: %s" % " ".join(extra))
    if not _run_build_cmd(
        # 关闭 Wasm 预检：flutter_secure_storage_web 等不兼容 Wasm，与当前 JS 产物无关，仅减少构建日志噪声。
        [flutter_cmd, "build", "web", "--release", "--no-wasm-dry-run", *extra],
        str(flutterapp),
        env,
    ):
        return False
    idx = flutterapp / "build" / "web" / "index.html"
    if not idx.is_file():
        print("未找到 flutterapp/build/web/index.html。")
        return False
    print("Flutter Web 已生成: %s" % idx)
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
        print(
            "已跳过移动端构建（HZTECH_SKIP_MOBILE_BUILD）；"
            "仅后续 build-web 等步骤会执行。"
        )
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
        print("未找到 gradlew 或 flutterapp，跳过 APK 构建。")
        return False
    if not (PROJECT_ROOT / "app" / "build.gradle.kts").exists():
        print("未找到 app/build.gradle.kts，跳过 APK 构建。")
        return False
    print("Building Android APK (assembleDebug) ...")
    if not _run_build_cmd(
        [str(GRADLEW), "assembleDebug", "-p", str(PROJECT_ROOT)],
        str(PROJECT_ROOT),
        dict(os.environ),
    ):
        return False
    apk_list = list(APK_DEBUG_DIR.glob("*.apk")) if APK_DEBUG_DIR.exists() else []
    if not apk_list:
        print("未找到生成的 APK 文件。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME_RELEASE
    shutil.copy2(apk_list[0], dest)
    print("APK 已复制到: %s" % dest)
    return True


def build_apk_debug() -> bool:
    """优先 Flutter debug APK，否则 Gradle assembleDebug；产物 apk/hztech-app-debug.apk。"""
    if build_apk_flutter_debug():
        return True
    if not GRADLEW.is_file():
        print("未找到 gradlew 或 flutterapp，跳过 APK 构建。")
        return False
    if not (PROJECT_ROOT / "app" / "build.gradle.kts").exists():
        print("未找到 app/build.gradle.kts，跳过 APK 构建。")
        return False
    print("Building Android APK (assembleDebug) ...")
    if not _run_build_cmd(
        [str(GRADLEW), "assembleDebug", "-p", str(PROJECT_ROOT)],
        str(PROJECT_ROOT),
        dict(os.environ),
    ):
        return False
    apk_list = list(APK_DEBUG_DIR.glob("*.apk")) if APK_DEBUG_DIR.exists() else []
    if not apk_list:
        print("未找到生成的 APK 文件。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME_DEBUG
    shutil.copy2(apk_list[0], dest)
    print("APK 已复制到: %s" % dest)
    return True


def run_build_mobile_debug() -> int:
    """仅构建 Android debug APK（不构建 iOS）。成功返回 0。"""
    if os.environ.get("HZTECH_SKIP_MOBILE_BUILD", "").strip().lower() in (
        "1",
        "true",
        "yes",
    ):
        print(
            "已跳过移动端构建（HZTECH_SKIP_MOBILE_BUILD）；"
            "仅后续 build-web 等步骤会执行。"
        )
        return 0
    if build_apk_debug():
        return 0
    return 1


def _remote_install_requirements_sh(remote_path: str) -> str:
    """远程 shell：在无 python3 -m pip 的机器上优先用 pip3（如 yum/dnf 装的 python3-pip）。"""
    pip3_or_mod = (
        "(command -v pip3 >/dev/null 2>&1 && "
        "pip3 install -r baasapi/requirements.txt -q --user || "
        "(python3 -c \"import pip\" 2>/dev/null && "
        "python3 -m pip install -r baasapi/requirements.txt -q --user) || "
        "(python3 -m ensurepip --user -q 2>/dev/null; "
        "python3 -m pip install -r baasapi/requirements.txt -q --user))"
    )
    return "cd %s && %s" % (remote_path, pip3_or_mod)


def _api_listen_port(cfg: dict) -> int:
    """BaasAPI 进程监听端口：baasapi_port / app_port。"""
    return int(cfg.get("baasapi_port", cfg.get("app_port", cfg.get("web_port", 9001))))


def run_verify_deploy() -> int:
    """HTTP 探测 BaasAPI /api/health 与 Flutter Web /（503 视为 Web 未构建但可达）。返回 0 全部成功。"""
    import urllib.error
    import urllib.request

    def _one(url: str, label: str) -> bool:
        try:
            with urllib.request.urlopen(url, timeout=15) as r:
                code = r.status
        except urllib.error.HTTPError as e:
            code = e.code
        except OSError:
            code = 0
        ok = code in (200, 503)
        print(
            "  %s %s -> HTTP %s (%s)"
            % ("OK" if ok else "WARN", label, code, url)
        )
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
        ok = _one("%s://%s:%s/api/health" % (scheme, ah, api_port), "BaasAPI health") and ok
        ok = _one("%s://%s:%s/" % (scheme, wh, web_port), "FlutterApp /") and ok
    else:
        ok = _one("%s://%s:%s/api/health" % (scheme, wh, api_port), "BaasAPI health") and ok
        ok = _one("%s://%s:%s/" % (scheme, wh, web_port), "FlutterApp /") and ok
    return 0 if ok else 1


def remote_restart_api():
    """在 BaasAPI 主机上启动完整后端（/api/*、/kline、/download 等 + DB + 定时任务）。"""
    c = target_config("baasapi")
    remote_path = c["remote_path"]
    api_port = _api_listen_port(c)
    host = c["host"]
    print("Restarting BaasAPI on %s (port=%s) ..." % (host, api_port))
    run_ssh(
        f"cd {remote_path} && pkill -f baasapi/main.py 2>/dev/null || true", check=False, cfg=c
    )
    run_ssh(f"cd {remote_path} && mkdir -p apk baasapi/sqlite", check=True, cfg=c)
    run_ssh(_remote_install_requirements_sh(remote_path), cfg=c)
    run_ssh(
        f"cd {remote_path} && {_remote_baasapi_start_env(remote_path, api_port)}"
        f"nohup python3 baasapi/main.py >> server.log 2>&1 & sleep 1",
        cfg=c,
    )
    print("BaasAPI restarted. Log: %s/server.log" % remote_path)


def remote_restart_web():
    """在 FlutterApp 主机上启动 Flutter Web 静态站（serve_web_static.py）；BaasAPI 在另一台机器时。"""
    c = target_config("flutterapp")
    remote_path = c["remote_path"]
    web_port = int(c.get("web_port", 9000))
    host = c["host"]
    web_root = f"{remote_path}/flutterapp/build/web"
    print(
        "Restarting FlutterApp static on %s (port=%s, root=%s) ..."
        % (host, web_port, web_root)
    )
    run_ssh(
        f"cd {remote_path} && pkill -f baasapi/serve_web_static.py 2>/dev/null || true",
        check=False,
        cfg=c,
    )
    # 双机时本机无 DB；不创建 baasapi/sqlite，并删除遗留目录
    run_ssh(
        f"cd {remote_path} && rm -rf baasapi/sqlite && mkdir -p apk res",
        check=True,
        cfg=c,
    )
    run_ssh(_remote_install_requirements_sh(remote_path), cfg=c)
    # pip 不应创建 DB 目录；与「仅 Web 机无库」一致，再清一次以防历史/误操作
    _flutter_host_remove_sqlite(c)
    run_ssh(
        f"cd {remote_path} && HZTECH_WEB_ROOT={web_root} PORT={web_port} "
        f"nohup python3 baasapi/serve_web_static.py >> web_static.log 2>&1 & sleep 1",
        cfg=c,
    )
    print("FlutterApp static restarted. Log: %s/web_static.log" % remote_path)


def remote_restart_single():
    """单主机部署：BaasAPI（main.py）+ FlutterApp 静态（serve_web_static.py）双进程。"""
    c = target_config("flutterapp")
    remote_path = c["remote_path"]
    web_port = int(c.get("web_port", 9000))
    api_port = _api_listen_port(c)
    web_root = f"{remote_path}/flutterapp/build/web"
    print(
        "Restarting API+Web on %s (API port=%s, Web port=%s) ..."
        % (c["host"], api_port, web_port)
    )
    run_ssh(
        "cd %s && pkill -f baasapi/main.py 2>/dev/null || true; "
        "pkill -f baasapi/serve_web_static.py 2>/dev/null || true" % remote_path,
        check=False,
    )
    run_ssh(f"cd {remote_path} && mkdir -p apk res baasapi/sqlite")
    run_ssh(_remote_install_requirements_sh(remote_path))
    run_ssh(
        f"cd {remote_path} && {_remote_baasapi_start_env(remote_path, api_port)}"
        f"nohup python3 baasapi/main.py >> server.log 2>&1 & sleep 1"
    )
    run_ssh(
        f"cd {remote_path} && HZTECH_WEB_ROOT={web_root} PORT={web_port} "
        f"nohup python3 baasapi/serve_web_static.py >> web_static.log 2>&1 & sleep 1"
    )
    print(
        "Server restarted. API: port %s (server.log)  Web: port %s (web_static.log)  root=%s"
        % (api_port, web_port, web_root)
    )


def remote_restart():
    """双机时先 API 后 Web；单机时与原先一致。"""
    if has_dual_deploy():
        remote_restart_api()
        remote_restart_web()
    else:
        remote_restart_single()


def remote_pip_install_only():
    """仅在远端执行 pip install -r baasapi/requirements.txt（双机则两台都执行）。"""
    if has_dual_deploy():
        c_api = target_config("baasapi")
        c_web = target_config("flutterapp")
        print("pip install on BaasAPI host %s ..." % c_api["host"])
        run_ssh(_remote_install_requirements_sh(c_api["remote_path"]), cfg=c_api)
        print("pip install on FlutterApp host %s ..." % c_web["host"])
        run_ssh(_remote_install_requirements_sh(c_web["remote_path"]), cfg=c_web)
        _flutter_host_remove_sqlite(c_web)
    else:
        rp = get_remote_path()
        print("pip install on %s ..." % target_config("flutterapp")["host"])
        run_ssh(_remote_install_requirements_sh(rp))
    print("Remote requirements install done.")


def deploy_and_start(port=None, start_server=True, rsync_mirror: bool = True):
    """同步到 AWS；可选在远程安装依赖并启动服务。"""
    c = load_config()
    cweb = target_config("flutterapp")
    if port is None:
        port = int(c.get("flutterapp_port", c.get("web_port", 9000)))
    if _deploy_apk_only_enabled():
        if has_dual_deploy():
            capi = target_config("baasapi")
            print(
                "Syncing APK only (%s) dual: BaasAPI %s + FlutterApp %s"
                % (DEFAULT_APK_NAME_RELEASE, capi["host"], cweb["host"])
            )
        else:
            print(
                "Syncing APK only (%s) → %s:%s"
                % (DEFAULT_APK_NAME_RELEASE, cweb["host"], cweb["remote_path"])
            )
    elif has_dual_deploy():
        capi = target_config("baasapi")
        print(
            "Syncing: BaasAPI (full backend) %s:%s → FlutterApp (web + apk only) %s:%s ..."
            % (capi["host"], capi["remote_path"], cweb["host"], cweb["remote_path"])
        )
    else:
        print("Syncing to %s:%s ..." % (cweb["host"], cweb["remote_path"]))
    rsync_sync(rsync_mirror=rsync_mirror)
    if not start_server:
        print("Sync done. Skip start. Run: python baasapi/server_mgr.py deploy --no-start")
        return
    remote_restart()
    web_port = int(c.get("flutterapp_port", c.get("web_port", 9000)))
    api_port = _api_listen_port(c)
    rp = get_remote_path()
    scheme = c.get("scheme", "http")
    if has_dual_deploy():
        capi = target_config("baasapi")
        print(
            "Deploy done. BaasAPI: %s://%s:%s/api/  FlutterApp: %s://%s:%s/  "
            "(logs: BaasAPI %s/server.log, FlutterApp %s/web_static.log)"
            % (
                scheme,
                capi["host"],
                api_port,
                scheme,
                cweb["host"],
                web_port,
                capi["remote_path"],
                rp,
            )
        )
    else:
        print(
            "Deploy done. BaasAPI: %s://%s:%s/api/  FlutterApp: %s://%s:%s/  "
            "(logs: %s/server.log, %s/web_static.log)"
            % (
                scheme,
                cweb["host"],
                api_port,
                scheme,
                cweb["host"],
                web_port,
                rp,
                rp,
            )
        )


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
            print("DB sync (user migrations) done on API host %s." % c_api["host"])
        else:
            remote_path = get_remote_path()
            run_ssh(f"cd {remote_path} && python3 -c 'from baasapi.db import init_db; init_db()'")
            print("DB sync (user migrations) done on remote.")
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "shell":
        subprocess.run(ssh_cmd(), cwd=PROJECT_ROOT)
        sys.exit(0)
    print("Config:", json.dumps(cfg, indent=2, ensure_ascii=False))
    target, key = get_ssh_target()
    print("SSH target:", target, "key:", key)
    print(
        "Usage: python server_mgr.py [build | build-debug | build-ios | build-web | deploy [--build] [--build-web] [--no-start] [--rsync-no-delete] | restart | pip-remote | db-sync | verify | shell]"
    )
