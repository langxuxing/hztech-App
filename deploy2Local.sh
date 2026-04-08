#!/usr/bin/env bash
# 本地一站式：pip requirements → Flutter 仅打 debug APK（apk/hztech-app-debug.apk）+ Web →（可选 init_db）→ 启动 run_local.sh
#
# 目录约定：运维脚本在项目根；Python 在 baasapi/（与 deploy2AWS、server_mgr 一致）。
#
# 默认行为（与「本地全栈联调」一致）：
#   · HZTECH_LOCAL_WEB_STATIC=1 → API + serve_web_static（端口见下），与 Web 构建配套
#   · 若只要 API（对齐 run_local.sh 默认）：export HZTECH_LOCAL_WEB_STATIC=0
#
# 环境变量：
#   HZTECH_SKIP_PIP_INSTALL=1   跳过本地 pip install -r baasapi/requirements.txt
#   HZTECH_SKIP_MOBILE_BUILD=1  跳过 APK/IPA 构建
#   HZTECH_SKIP_IOS_BUILD       server_mgr 默认不编 iOS；本地仅 build-debug（无 IPA）
#   HZTECH_SKIP_WEB_BUILD=1      跳过 flutter build web
#   数据库迁移（init_db）：默认不执行；仅当以下任一成立时执行：
#     · 命令行: --db / --db-sync / --init-db / -db
#     · HZTECH_DB_SYNC=1（或 true/yes）
#     · HZTECH_SKIP_DB_SYNC=0（显式要求同步，兼容旧脚本）
#   HZTECH_SKIP_DB_SYNC=1       强制跳过（若同时传 --db，则以 --db 为准）
#   HZTECH_SSH_INSTALL_PG_AWS_ALPHA=1  先 SSH 到远端安装 PostgreSQL（默认 Host aws-alpha；对应 BaasAPI 54.66.108.150，见 baasapi/deploy-aws.json）
#   HZTECH_SSH_PG_TARGET=aws-alpha     上项开启时可覆盖 SSH 目标（主机别名或 user@host，亦可用 ec2-user@54.66.108.150）
#   HZTECH_PG_USER / HZTECH_PG_PASSWORD / HZTECH_PG_DB / HZTECH_PG_SCHEMA  远端库账号（默认 hztech / Alpha / hztech / flutterapp）
#   HZTECH_SSH_OPTS                传给 ssh 的额外选项（慎用；一般依赖 ssh config 即可）
#   HZTECH_LOCAL_API_PORT / HZTECH_LOCAL_WEB_PORT / HZTECH_LOCAL_WEB_STATIC
#   HZTECH_ACCOUNT_SYNC_INTERVAL_SEC  账户 OKX 定时同步间隔（秒）；未设置时 main.py 默认 300
#   HZTECH_API_BASE_URL         未设置时默认 http://192.168.3.41:9001/（局域网联调；与 dart_defines/local.json）
#                                仅用本机 API 时: export HZTECH_API_BASE_URL=http://127.0.0.1:${HZTECH_LOCAL_API_PORT}/
#   FLUTTER_DART_DEFINE_FILE    传给 Flutter 构建；HZTECH_API_BASE_URL 优先于文件内 API_BASE_URL
#   PORT                        与 HZTECH_LOCAL_API_PORT 共用时的回退
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# 默认不执行 init_db；见文件头「数据库迁移」说明
_DB_SYNC_FLAG=0
_argv=()
for _a in "$@"; do
  case "$_a" in
  --db | --db-sync | --init-db | -db)
    _DB_SYNC_FLAG=1
    ;;
  *)
    _argv+=("$_a")
    ;;
  esac
done
# set -u：空数组时 "${_argv[@]}" 在 bash 3.2（macOS 默认）会报 unbound variable
set +u
if [[ ${#_argv[@]} -gt 0 ]]; then
  set -- "${_argv[@]}"
else
  set --
fi
unset _a _argv
set -u

_run_db_sync=0
if [[ "$_DB_SYNC_FLAG" -eq 1 ]]; then
  _run_db_sync=1
elif [[ "${HZTECH_SKIP_DB_SYNC:-}" == "0" ]]; then
  _run_db_sync=1
else
  _sk=$(printf '%s' "${HZTECH_SKIP_DB_SYNC:-}" | tr '[:upper:]' '[:lower:]')
  if [[ "$_sk" == "1" || "$_sk" == "true" || "$_sk" == "yes" ]]; then
    _run_db_sync=0
  else
    _ds=$(printf '%s' "${HZTECH_DB_SYNC:-}" | tr '[:upper:]' '[:lower:]')
    if [[ "$_ds" == "1" || "$_ds" == "true" || "$_ds" == "yes" ]]; then
      _run_db_sync=1
    fi
  fi
fi
unset _DB_SYNC_FLAG _sk _ds

_ssh_pg=$(printf '%s' "${HZTECH_SSH_INSTALL_PG_AWS_ALPHA:-}" | tr '[:upper:]' '[:lower:]')
if [[ "$_ssh_pg" == "1" || "$_ssh_pg" == "true" || "$_ssh_pg" == "yes" ]]; then
  printf '\n'
  echo "=== （可选）远端 PostgreSQL（HZTECH_SSH_INSTALL_PG_AWS_ALPHA，SSH: ${HZTECH_SSH_PG_TARGET:-aws-alpha}）==="
  bash "$PROJECT_ROOT/baasapi/install_postgresql_remote.sh" "${HZTECH_SSH_PG_TARGET:-aws-alpha}"
fi
unset _ssh_pg

if ! command -v python3 >/dev/null 2>&1; then
  echo "错误: 需要 python3" >&2
  exit 1
fi
_HZTECH_PYTHON3="$(command -v python3)"
[[ -n "$_HZTECH_PYTHON3" ]] || {
  echo "错误: 无法解析 python3 路径" >&2
  exit 1
}

# 默认开启 Web 静态进程，与「已构建 Web」流程一致；仅 API 时显式设为 0
export HZTECH_LOCAL_API_PORT="${HZTECH_LOCAL_API_PORT:-${PORT:-9001}}"
export HZTECH_LOCAL_WEB_PORT="${HZTECH_LOCAL_WEB_PORT:-9000}"
export HZTECH_LOCAL_WEB_STATIC="${HZTECH_LOCAL_WEB_STATIC:-1}"

# 数据库：默认 PostgreSQL（可用 HZTECH_DB_BACKEND/HZTECH_DB_CONFIG 覆盖）
#   - 缺省: HZTECH_DB_BACKEND=postgresql
#   - 如需 SQLite（仅本地临时调试）:
#       export HZTECH_DB_BACKEND=sqlite
#       export HZTECH_DB_CONFIG=baasapi/database_config.local.sqlite.json
_DB_JSON="$PROJECT_ROOT/baasapi/database_config.json"
_DB_SQLITE_TMPL="$PROJECT_ROOT/baasapi/database_config.local.sqlite.json"
export HZTECH_DB_BACKEND="${HZTECH_DB_BACKEND:-postgresql}"
if [[ "${HZTECH_DB_BACKEND}" == "sqlite" && -z "${HZTECH_DB_CONFIG:-}" && -f "$_DB_SQLITE_TMPL" ]]; then
  export HZTECH_DB_CONFIG="$_DB_SQLITE_TMPL"
fi
unset _DB_JSON _DB_SQLITE_TMPL

export HZTECH_API_BASE_URL="${HZTECH_API_BASE_URL:-http://192.168.3.41:9001/}"
export FLUTTER_DART_DEFINE_FILE="${FLUTTER_DART_DEFINE_FILE:-flutterapp/dart_defines/local.json}"
export HZTECH_SKIP_IOS_BUILD="${HZTECH_SKIP_IOS_BUILD:-1}"
# 与 server_mgr build-debug 产物一致；/api/app-version 与下载页默认指向 debug APK
export HZTECH_APP_ANDROID_APK="${HZTECH_APP_ANDROID_APK:-hztech-app-debug.apk}"

echo "=============================================="
echo "  本地部署: Flutter 构建 -> 启动本地服务"
echo "  端口: API=${HZTECH_LOCAL_API_PORT}  Web 静态=${HZTECH_LOCAL_WEB_PORT}"
echo "  HZTECH_LOCAL_WEB_STATIC=${HZTECH_LOCAL_WEB_STATIC}"
echo "    1 = 同时启动 API + Flutter Web 静态 (双进程)"
echo "    0 = 仅 API (与单独运行 baasapi/run_local.sh 默认一致)"
echo "  构建用 API_BASE_URL: ${HZTECH_API_BASE_URL}"
echo "  局域网约定 Web/App → BaasAPI（Debug 与 Release 构建缺省一致）:"
echo "    http://192.168.3.41:9001/"
echo "=============================================="

case "${HZTECH_SKIP_PIP_INSTALL:-}" in
1 | true | yes)
  printf '\n'
  echo "=== 1/5 跳过 Python 依赖（HZTECH_SKIP_PIP_INSTALL）==="
  ;;
*)
  printf '\n'
  echo "=== 1/5 安装 Python 依赖（baasapi/requirements.txt）==="
  "$PROJECT_ROOT/baasapi/install_python_deps.sh"
  ;;
esac

_skmb=$(printf '%s' "${HZTECH_SKIP_MOBILE_BUILD:-}" | tr '[:upper:]' '[:lower:]')
if [[ "$_skmb" == "1" || "$_skmb" == "true" || "$_skmb" == "yes" ]]; then
  printf '\n'
  echo "=== 2/5 跳过 Flutter 移动端（HZTECH_SKIP_MOBILE_BUILD）==="
else
  printf '\n'
  echo "=== 2/5 构建 Flutter 移动端（debug APK → apk/hztech-app-debug.apk）==="
  "$_HZTECH_PYTHON3" "$PROJECT_ROOT/baasapi/server_mgr.py" build-debug
  echo "  APK: $PROJECT_ROOT/apk/hztech-app-debug.apk"
fi

if [[ "${HZTECH_SKIP_WEB_BUILD:-0}" == "1" ]]; then
  printf '\n'
  echo "=== 3/5 跳过 Flutter Web（HZTECH_SKIP_WEB_BUILD=1）==="
  if [[ "$HZTECH_LOCAL_WEB_STATIC" == "1" ]] && [[ ! -f "$PROJECT_ROOT/flutterapp/build/web/index.html" ]]; then
    echo "  警告: 未找到 flutterapp/build/web/index.html，Web 静态可能 503。请构建 Web 或关闭 HZTECH_LOCAL_WEB_STATIC。" >&2
  fi
else
  printf '\n'
  echo "=== 3/5 构建 Flutter Web (release) ==="
  if "$_HZTECH_PYTHON3" "$PROJECT_ROOT/baasapi/server_mgr.py" build-web; then
    echo "  Web: $PROJECT_ROOT/flutterapp/build/web/"
  else
    echo "  （Web 构建失败；若 HZTECH_LOCAL_WEB_STATIC=1 则静态站可能不可用）" >&2
  fi
fi

if [[ "$_run_db_sync" -eq 1 ]]; then
  printf '\n'
  echo "=== 4/5 同步本地数据库（用户迁移）==="
  "$_HZTECH_PYTHON3" -c "from baasapi.db import init_db; init_db()"
  echo "  数据库已就绪"
else
  printf '\n'
  echo "=== 4/5 跳过本地 DB（默认不迁移；需要时请传 --db 或 HZTECH_DB_SYNC=1）==="
fi
unset _run_db_sync

printf '\n'
echo "=== 5/5 启动服务 (端口与访问方式见 baasapi/run_local.sh 输出) ==="
export FLASK_DEBUG=1
export LOG_LEVEL=DEBUG
exec "$PROJECT_ROOT/baasapi/run_local.sh"
