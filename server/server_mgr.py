"""AWS 部署配置与 SSH 管理。从 server/deploy-aws.json 读取，供 Cursor/脚本部署到 AWS。"""
from pathlib import Path
import json
import os
import shutil
import subprocess

# 项目根目录（server 的上一级）
PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = PROJECT_ROOT / "server" / "deploy-aws.json"
GRADLEW = PROJECT_ROOT / "gradlew"
FLUTTER_APP = PROJECT_ROOT / "flutter_app"
APK_DEBUG_DIR = PROJECT_ROOT / "app" / "build" / "outputs" / "apk" / "debug"
FLUTTER_APK_DIR = FLUTTER_APP / "build" / "app" / "outputs" / "flutter-apk"
# 生成 APK 放入项目根下 apk/，部署后对应 AWS 上 hztechapp/apk/（见 deploy-aws.json remote_path）
APK_DIR = PROJECT_ROOT / "apk"
DEFAULT_APK_NAME = "禾正量化-release.apk"


def load_config():
    with open(CONFIG_PATH, encoding="utf-8") as f:
        return json.load(f)


def target_config(role: str) -> dict:
    """合并顶层字段与 web / api 段。role 为 'web' 或 'api'。"""
    c = load_config()
    keys = ("name", "scheme", "web_port", "app_port", "user", "key", "ssh_opts")
    base = {k: c[k] for k in keys if k in c}
    nested = c.get(role)
    if isinstance(nested, dict):
        merged = {**base, **nested}
        return merged
    # 兼容旧版单主机：顶层 host + remote_path
    if "host" in c and "remote_path" in c:
        return {**base, **{k: c[k] for k in ("host", "port", "remote_path") if k in c}}
    raise KeyError("deploy-aws.json 缺少 web/api 段或旧版 host/remote_path")


def has_dual_deploy() -> bool:
    c = load_config()
    return isinstance(c.get("api"), dict) and isinstance(c.get("web"), dict)


def get_ssh_target():
    """返回 (user@host, key_path) 用于 SSH/rsync（默认 Web 主机）。"""
    c = target_config("web")
    key = PROJECT_ROOT / c["key"]
    return f"{c['user']}@{c['host']}", str(key)


def get_remote_path():
    """远程 Web 部署目录。"""
    return target_config("web")["remote_path"]


def ssh_cmd(remote_cmd=None, cfg=None):
    """构建 ssh 命令。remote_cmd 为 None 时打开交互 shell。cfg 默认 Web 主机。"""
    c = cfg if cfg is not None else target_config("web")
    key = PROJECT_ROOT / c["key"]
    port = c.get("port", 22)
    opts = c.get("ssh_opts", [])
    base = ["ssh", "-i", str(key), "-p", str(port)] + opts + [f"{c['user']}@{c['host']}"]
    if remote_cmd is not None:
        base.append(remote_cmd)
    return base


def run_ssh(remote_cmd, check=True, cfg=None):
    """在 AWS 上执行单条命令。check=False 时忽略非零退出码（如 pkill 无匹配）。"""
    subprocess.run(ssh_cmd(remote_cmd, cfg=cfg), check=check, cwd=PROJECT_ROOT)


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
        "flutter_app",
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
        "server/deploy-aws.json",
        "server/server_mgr.py",
        "server/README-DEPLOY.md",
        "server/test_server.sh",
        "server/install_on_aws.sh",
        "server/run_local.sh",
        "server/run_apk_debug.sh",
        "server/build_and_deploy.sh",
        "server/seed_mock_account_data.py",
        "server/seed_test_seasons.py",
        "server/seed_test_profit_data.py",
        "server/Accounts/test_account_key.py",
    ]


def _rsync_one(cfg: dict, extra_excludes: list | None, sync_flutter_web: bool):
    """同步项目根到指定主机。extra_excludes 追加排除项；sync_flutter_web 为 True 时再同步 flutter build/web。"""
    key = PROJECT_ROOT / cfg["key"]
    remote_base = f"{cfg['user']}@{cfg['host']}:{cfg['remote_path']}"
    key_str = str(key)
    excludes: list[str] = []
    for pat in _rsync_deploy_exclude_patterns():
        excludes.extend(["--exclude", pat])
    if extra_excludes:
        for x in extra_excludes:
            excludes.extend(["--exclude", x])
    port = cfg.get("port", 22)
    ssh_e = f"ssh -i {key_str} -p {port} -o StrictHostKeyChecking=accept-new"
    cmd = ["rsync", "-avz", "--delete"]
    cmd.extend(excludes)
    cmd.extend(["-e", ssh_e])
    cmd.extend([str(PROJECT_ROOT) + "/", remote_base + "/"])
    subprocess.run(cmd, check=True, cwd=PROJECT_ROOT)
    if not sync_flutter_web:
        return
    web_src = FLUTTER_APP / "build" / "web"
    if web_src.is_dir() and (web_src / "index.html").is_file():
        remote_web = remote_base + "/flutter_app/build/web/"
        subprocess.run(
            ["rsync", "-avz", "--delete", "-e", ssh_e, str(web_src) + "/", remote_web],
            check=True,
            cwd=PROJECT_ROOT,
        )


def rsync_sync(exclude=None):
    """同步到 Web 主机（精简目录 + Flutter Web）；双机时 API 主机再同步一份（不含 flutter_app、apk）。
    排除项见 _rsync_deploy_exclude_patterns（测试/IDE/Gradle/Dart 源码/本地部署脚本等）。"""
    ex = list(exclude) if exclude else []
    c_web = target_config("web")
    _rsync_one(c_web, ex, sync_flutter_web=True)
    if has_dual_deploy():
        c_api = target_config("api")
        api_ex = ex + ["flutter_app", "apk"]
        _rsync_one(c_api, api_ex, sync_flutter_web=False)


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
    """
    args: list[str] = []
    url = os.environ.get("HZTECH_API_BASE_URL", "").strip()
    if url:
        args.extend(["--dart-define", "API_BASE_URL=%s" % url])
        return args
    f = os.environ.get("FLUTTER_DART_DEFINE_FILE", "").strip()
    if not f:
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


def build_apk_flutter():
    """使用 Flutter 编译 release APK，并复制到 apk/。"""
    if not FLUTTER_APP.is_dir():
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
    subprocess.run(
        [flutter_cmd, "build", "apk", "--release", *extra],
        check=True,
        cwd=str(FLUTTER_APP),
        env=env,
    )
    apk = FLUTTER_APK_DIR / "app-release.apk"
    if not apk.is_file():
        print("未找到 Flutter 生成的 app-release.apk。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME
    shutil.copy2(apk, dest)
    print("APK 已复制到: %s" % dest)
    return True


def build_web_flutter():
    """flutter build web，供 Flask 托管 flutter_app/build/web。"""
    if not FLUTTER_APP.is_dir():
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
    subprocess.run(
        [flutter_cmd, "build", "web", "--release", *extra],
        check=True,
        cwd=str(FLUTTER_APP),
        env=env,
    )
    idx = FLUTTER_APP / "build" / "web" / "index.html"
    if not idx.is_file():
        print("未找到 flutter_app/build/web/index.html。")
        return False
    print("Flutter Web 已生成: %s" % idx)
    return True


def build_apk():
    """优先 Flutter 构建，否则使用 Gradle 构建原生 debug APK。"""
    if build_apk_flutter():
        return True
    if not GRADLEW.is_file():
        print("未找到 gradlew 或 flutter_app，跳过 APK 构建。")
        return False
    if not (PROJECT_ROOT / "app" / "build.gradle.kts").exists():
        print("未找到 app/build.gradle.kts，跳过 APK 构建。")
        return False
    print("Building Android APK (assembleDebug) ...")
    subprocess.run(
        [str(GRADLEW), "assembleDebug", "-p", str(PROJECT_ROOT)],
        check=True,
        cwd=PROJECT_ROOT,
    )
    apk_list = list(APK_DEBUG_DIR.glob("*.apk")) if APK_DEBUG_DIR.exists() else []
    if not apk_list:
        print("未找到生成的 APK 文件。")
        return False
    APK_DIR.mkdir(parents=True, exist_ok=True)
    dest = APK_DIR / DEFAULT_APK_NAME
    shutil.copy2(apk_list[0], dest)
    print("APK 已复制到: %s" % dest)
    return True


def _remote_install_requirements_sh(remote_path: str) -> str:
    """远程 shell：在无 python3 -m pip 的机器上优先用 pip3（如 yum/dnf 装的 python3-pip）。"""
    pip3_or_mod = (
        "(command -v pip3 >/dev/null 2>&1 && "
        "pip3 install -r server/requirements.txt -q --user || "
        "(python3 -c \"import pip\" 2>/dev/null && "
        "python3 -m pip install -r server/requirements.txt -q --user) || "
        "(python3 -m ensurepip --user -q 2>/dev/null; "
        "python3 -m pip install -r server/requirements.txt -q --user))"
    )
    return "cd %s && %s" % (remote_path, pip3_or_mod)


def remote_restart_api():
    """在 API 主机上启动完整后端（/api/* + DB + 定时任务）。"""
    c = target_config("api")
    remote_path = c["remote_path"]
    web_port = c.get("web_port", 9000)
    host = c["host"]
    print("Restarting API server on %s (port=%s) ..." % (host, web_port))
    run_ssh(
        f"cd {remote_path} && pkill -f server/main.py 2>/dev/null || true", check=False, cfg=c
    )
    run_ssh(f"cd {remote_path} && mkdir -p apk server/sqlite", check=True, cfg=c)
    run_ssh(_remote_install_requirements_sh(remote_path), cfg=c)
    run_ssh(
        f"cd {remote_path} && unset HZTECH_STATIC_ONLY; MOBILEAPP_ROOT={remote_path} PORT={web_port} "
        f"nohup python3 server/main.py >> server.log 2>&1 & sleep 1",
        cfg=c,
    )
    print("API server restarted. Log: %s/server.log" % remote_path)


def remote_restart_web():
    """在 Web 主机上启动仅静态站点（Flutter Web + APK + /res；API 在另一台机器）。"""
    c = target_config("web")
    remote_path = c["remote_path"]
    web_port = c.get("web_port", 9000)
    host = c["host"]
    print("Restarting Web (static) on %s (port=%s) ..." % (host, web_port))
    run_ssh(
        f"cd {remote_path} && pkill -f server/main.py 2>/dev/null || true", check=False, cfg=c
    )
    run_ssh(f"cd {remote_path} && mkdir -p apk res", check=True, cfg=c)
    run_ssh(_remote_install_requirements_sh(remote_path), cfg=c)
    run_ssh(
        f"cd {remote_path} && HZTECH_STATIC_ONLY=1 MOBILEAPP_ROOT={remote_path} PORT={web_port} "
        f"nohup python3 server/main.py >> server.log 2>&1 & sleep 1",
        cfg=c,
    )
    print("Web server restarted. Log: %s/server.log" % remote_path)


def remote_restart_single():
    """单主机部署：REST API + Flutter Web 同一进程。"""
    c = target_config("web")
    remote_path = c["remote_path"]
    web_port = c.get("web_port", 9000)
    print(
        "Restarting server on %s (port=%s, API+Web) ..." % (c["host"], web_port)
    )
    run_ssh(f"cd {remote_path} && pkill -f server/main.py 2>/dev/null || true", check=False)
    run_ssh(f"cd {remote_path} && mkdir -p apk res")
    run_ssh(_remote_install_requirements_sh(remote_path))
    run_ssh(
        f"cd {remote_path} && unset HZTECH_STATIC_ONLY; MOBILEAPP_ROOT={remote_path} PORT={web_port} "
        f"nohup python3 server/main.py >> server.log 2>&1 & sleep 1"
    )
    print(
        "Server restarted. URL: port %s (/api/* + Flutter Web). Log: %s/server.log"
        % (web_port, remote_path)
    )


def remote_restart():
    """双机时先 API 后 Web；单机时与原先一致。"""
    if has_dual_deploy():
        remote_restart_api()
        remote_restart_web()
    else:
        remote_restart_single()


def deploy_and_start(port=None, start_server=True):
    """同步到 AWS；可选在远程安装依赖并启动服务。"""
    c = load_config()
    cweb = target_config("web")
    if port is None:
        port = int(c.get("web_port", 9000))
    if has_dual_deploy():
        capi = target_config("api")
        print(
            "Syncing to API %s:%s and Web %s:%s ..."
            % (capi["host"], capi["remote_path"], cweb["host"], cweb["remote_path"])
        )
    else:
        print("Syncing to %s:%s ..." % (cweb["host"], cweb["remote_path"]))
    rsync_sync()
    if not start_server:
        print("Sync done. Skip start. Run: python server/server_mgr.py deploy --no-start")
        return
    remote_restart()
    web_port = c.get("web_port", 9000)
    rp = get_remote_path()
    scheme = c.get("scheme", "http")
    if has_dual_deploy():
        capi = target_config("api")
        print(
            "Deploy done. API: %s://%s:%s/api/  Web: %s://%s:%s/  (logs: API %s/server.log, Web %s/server.log)"
            % (
                scheme,
                capi["host"],
                web_port,
                scheme,
                cweb["host"],
                web_port,
                capi["remote_path"],
                rp,
            )
        )
    else:
        print(
            "Deploy done. Base URL: %s://%s:%s  ( /api/* + / )  Log: %s/server.log"
            % (scheme, cweb["host"], web_port, rp)
        )


if __name__ == "__main__":
    import sys
    cfg = load_config()
    if len(sys.argv) > 1 and sys.argv[1] == "build":
        build_apk()
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "build-web":
        ok = build_web_flutter()
        sys.exit(0 if ok else 1)
    if len(sys.argv) > 1 and sys.argv[1] == "deploy":
        start = "--no-start" not in sys.argv
        do_build = "--build" in sys.argv
        if do_build:
            build_apk()
        if "--build-web" in sys.argv:
            build_web_flutter()
        deploy_and_start(port=int(cfg.get("web_port", cfg.get("port", 9000))), start_server=start)
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "restart":
        remote_restart()
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "db-sync":
        if has_dual_deploy():
            c_api = target_config("api")
            remote_path = c_api["remote_path"]
            run_ssh(
                f"cd {remote_path} && python3 -c 'from server.db import init_db; init_db()'",
                cfg=c_api,
            )
            print("DB sync (user migrations) done on API host %s." % c_api["host"])
        else:
            remote_path = get_remote_path()
            run_ssh(f"cd {remote_path} && python3 -c 'from server.db import init_db; init_db()'")
            print("DB sync (user migrations) done on remote.")
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "shell":
        subprocess.run(ssh_cmd(), cwd=PROJECT_ROOT)
        sys.exit(0)
    print("Config:", json.dumps(cfg, indent=2, ensure_ascii=False))
    target, key = get_ssh_target()
    print("SSH target:", target, "key:", key)
    print(
        "Usage: python server_mgr.py [build | build-web | deploy [--build] [--build-web] [--no-start] | restart | db-sync | shell]"
    )
