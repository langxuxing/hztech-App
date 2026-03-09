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
# 生成 APK 放入项目根下 apk/，部署后对应 AWS 上 mobileapp/apk/
APK_DIR = PROJECT_ROOT / "apk"
DEFAULT_APK_NAME = "禾正量化-release.apk"


def load_config():
    with open(CONFIG_PATH, encoding="utf-8") as f:
        return json.load(f)


def get_ssh_target():
    """返回 (user@host, key_path) 用于 SSH/rsync。"""
    c = load_config()
    key = PROJECT_ROOT / c["key"]
    return f"{c['user']}@{c['host']}", str(key)


def get_remote_path():
    """远程部署目录。"""
    return load_config()["remote_path"]


def ssh_cmd(remote_cmd=None):
    """构建 ssh 命令。remote_cmd 为 None 时打开交互 shell。"""
    c = load_config()
    key = PROJECT_ROOT / c["key"]
    port = c.get("port", 22)
    opts = c.get("ssh_opts", [])
    base = ["ssh", "-i", str(key), "-p", str(port)] + opts + [f"{c['user']}@{c['host']}"]
    if remote_cmd is not None:
        base.append(remote_cmd)
    return base


def run_ssh(remote_cmd, check=True):
    """在 AWS 上执行单条命令。check=False 时忽略非零退出码（如 pkill 无匹配）。"""
    subprocess.run(ssh_cmd(remote_cmd), check=check, cwd=PROJECT_ROOT)


def rsync_sync(exclude=None):
    """使用 rsync 同步项目到 AWS。会同步：server/（后端+Web 页面+res）、apk/ 等；排除 .git、flutter_app/（仅上传构建好的 APK 到 apk/，不上传 Flutter 源码）等。"""
    c = load_config()
    key = PROJECT_ROOT / c["key"]
    remote = f"{c['user']}@{c['host']}:{c['remote_path']}"
    key_str = str(key)
    excludes = [
        "--exclude", ".git",
        "--exclude", "app/build",
        "--exclude", "flutter_app",  # 只上传 apk/ 中的构建产物，不上传 Flutter 源码
        "--exclude", ".gradle",
        "--exclude", ".idea",
        "--exclude", "*.iml",
        "--exclude", ".mypy_cache",
        "--exclude", "__pycache__",
        "--exclude", "*.pyc",
    ]
    if exclude:
        for x in exclude:
            excludes.extend(["--exclude", x])
    port = c.get("port", 22)
    cmd = ["rsync", "-avz", "--delete"]
    cmd.extend(excludes)
    cmd.extend([f"-e", f"ssh -i {key_str} -p {port} -o StrictHostKeyChecking=accept-new"])
    cmd.extend([str(PROJECT_ROOT) + "/", remote])
    subprocess.run(cmd, check=True, cwd=PROJECT_ROOT)


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
    subprocess.run(
        [flutter_cmd, "build", "apk", "--release"],
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


def remote_restart():
    """在 AWS 上停止旧进程、安装依赖并启动双进程（Web=9000 + API=9001）。"""
    c = load_config()
    remote_path = get_remote_path()
    web_port = c.get("web_port", 9000)
    app_port = c.get("app_port", 9001)
    print("Restarting server on %s (Web=%s, API=%s) ..." % (c["host"], web_port, app_port))
    run_ssh(f"cd {remote_path} && pkill -f server/app.py 2>/dev/null || true", check=False)
    run_ssh(f"cd {remote_path} && mkdir -p apk res")
    run_ssh(f"cd {remote_path} && python3 -m pip install -r server/requirements.txt -q --user")
    run_ssh(
        f"cd {remote_path} && MOBILEAPP_ROOT={remote_path} PORT={web_port} nohup python3 server/app.py >> server_web.log 2>&1 & "
        f"MOBILEAPP_ROOT={remote_path} PORT={app_port} nohup python3 server/app.py >> server_api.log 2>&1 & sleep 1"
    )
    print("Server restarted. Web: port %s, API: port %s. Logs: %s/server_web.log, %s/server_api.log" % (web_port, app_port, remote_path, remote_path))


def deploy_and_start(port=9001, start_server=True):
    """同步到 AWS；可选在远程安装依赖并启动服务（Web + API 双进程）。"""
    c = load_config()
    print("Syncing to %s:%s ..." % (c["host"], c["remote_path"]))
    rsync_sync()
    if not start_server:
        print("Sync done. Skip start. Run: python server/server_mgr.py deploy --no-start")
        return
    remote_restart()
    web_port = c.get("web_port", 9000)
    app_port = c.get("app_port", 9001)
    rp = get_remote_path()
    scheme = c.get("scheme", "http")
    print("Deploy done. Web: %s://%s:%s  API: %s://%s:%s  Logs: %s/server_web.log, %s/server_api.log" % (scheme, c["host"], web_port, scheme, c["host"], app_port, rp, rp))


if __name__ == "__main__":
    import sys
    cfg = load_config()
    if len(sys.argv) > 1 and sys.argv[1] == "build":
        build_apk()
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "deploy":
        start = "--no-start" not in sys.argv
        do_build = "--build" in sys.argv
        if do_build:
            build_apk()
        deploy_and_start(port=int(cfg.get("app_port", cfg.get("port", 9001))), start_server=start)
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "restart":
        remote_restart()
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "db-sync":
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
    print("Usage: python server_mgr.py [build | deploy [--build] [--no-start] | restart | db-sync | shell]")
