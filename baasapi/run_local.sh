#!/usr/bin/env bash
# 本地启动（默认：仅 API 单进程，与线上 API 节点一致）
#   · API：PORT 默认 9001，python3 baasapi/main.py（/api/*、/kline/*、/download 等）
# 同时起 Flutter Web 静态（本地双进程）：HZTECH_LOCAL_WEB_STATIC=1 ./baasapi/run_local.sh
#   · Web：PORT 默认 9000，python3 baasapi/serve_web_static.py（flutterapp/build/web）
# 在项目根目录执行：./baasapi/run_local.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

export MOBILEAPP_ROOT="$PROJECT_ROOT"
# 本地默认：DEBUG 日志、Flask debug（含热重载）、进程内 HTTP 统计（GET /api/status → http_request_stats）
# 安静/类生产：LOG_LEVEL=INFO FLASK_DEBUG=0 ./baasapi/run_local.sh
export LOG_LEVEL="${LOG_LEVEL:-DEBUG}"
export FLASK_DEBUG="${FLASK_DEBUG:-1}"
export HZTECH_API_REQUEST_STATS="${HZTECH_API_REQUEST_STATS:-1}"
# 交易机器人 shell：本地缺省为仓库内 baasapi/accounts/tradingbot_ctrl（勿与 AWS /home/ec2-user/Alpha 混用）
export HZTECH_TRADINGBOT_CTRL_DIR="${HZTECH_TRADINGBOT_CTRL_DIR:-$PROJECT_ROOT/baasapi/accounts/tradingbot_ctrl}"
# 本地默认读 Account_List.json；生产见 aws-ops/code/install_on_aws.sh / server_mgr 远端启动（database）
export HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE="${HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE:-json}"

# 数据库：优先 database_config.json；否则自动使用 database_config.local.sqlite.json（SQLite，见 deploy2Local.sh）
_DB_JSON="$SCRIPT_DIR/database_config.json"
_DB_SQLITE_TMPL="$SCRIPT_DIR/database_config.local.sqlite.json"
if [[ -f "$_DB_JSON" ]]; then
  export HZTECH_DB_BACKEND="${HZTECH_DB_BACKEND:-postgresql}"
elif [[ -f "$_DB_SQLITE_TMPL" ]]; then
  export HZTECH_DB_CONFIG="${HZTECH_DB_CONFIG:-$_DB_SQLITE_TMPL}"
else
  export HZTECH_DB_BACKEND="${HZTECH_DB_BACKEND:-auto}"
fi
unset _DB_JSON _DB_SQLITE_TMPL

_hztech_resolve_python() {
  if [[ -n "${HZTECH_PYTHON:-}" && -x "${HZTECH_PYTHON}" ]]; then
    printf '%s' "${HZTECH_PYTHON}"
    return
  fi
  if [[ -x "$SCRIPT_DIR/.venv/bin/python" ]]; then
    printf '%s' "$SCRIPT_DIR/.venv/bin/python"
    return
  fi
  command -v python3
}
_PY="$(_hztech_resolve_python)"

# 与 aws-ops/code/install_python_deps.sh 安装的 venv / 当前解释器一致（与 deploy2Local 共用）
case "${HZTECH_SKIP_PIP_INSTALL:-}" in
1 | true | yes) ;;
*)
  if ! "$_PY" -c "import flask, jwt, requests, ccxt" 2>/dev/null; then
    echo "检测到缺少 BaasAPI 运行时依赖，正在安装 baasapi/requirements.txt ..."
    "$PROJECT_ROOT/ops/code/install_python_deps.sh" || exit 1
    _PY="$(_hztech_resolve_python)"
  fi
  ;;
esac

_hztech_lan_ip() {
  local ip=""
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  else
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  echo "${ip:-}"
}
_LAN=$(_hztech_lan_ip)

API_PORT="${HZTECH_LOCAL_API_PORT:-9001}"
WEB_PORT="${HZTECH_LOCAL_WEB_PORT:-9000}"
# 默认仅 API；与 Flutter Web 联调时 export HZTECH_LOCAL_WEB_STATIC=1
WEB_STATIC="${HZTECH_LOCAL_WEB_STATIC:-0}"
WEB_ROOT="${HZTECH_WEB_ROOT:-$PROJECT_ROOT/flutterapp/build/web}"

_hztech_echo_mobile_api_urls() {
  local p="$1"
  echo "  手机访问 API (本机服务):"
  echo "    模拟器  http://10.0.2.2:${p}/"
  if [[ -n "$_LAN" ]]; then
    echo "    真机    http://${_LAN}:${p}/"
  else
    echo "    真机    http://<本机局域网IP>:${p}/"
  fi
}

if [[ "$WEB_STATIC" != "1" ]]; then
  echo "=============================================="
  echo "  本地启动: 仅 API (单进程, 端口 ${API_PORT})"
  echo "  HZTECH_LOCAL_WEB_STATIC=${WEB_STATIC}  FLASK_DEBUG=${FLASK_DEBUG}  LOG_LEVEL=${LOG_LEVEL}  HZTECH_API_REQUEST_STATS=${HZTECH_API_REQUEST_STATS}"
  echo ""
  echo "  本机浏览器 / curl:"
  echo "    API  http://127.0.0.1:${API_PORT}/"
  _hztech_echo_mobile_api_urls "$API_PORT"
  echo ""
  echo "  需要同时起 Flutter Web 静态 (双进程, 默认 Web 端口 ${WEB_PORT}):"
  echo "    HZTECH_LOCAL_WEB_STATIC=1 $0"
  echo "  停止: Ctrl+C"
  echo "=============================================="
  echo ""
  exec env PORT="$API_PORT" "$_PY" baasapi/main.py
fi

_API_PID=""
_WEB_PID=""
cleanup() {
  [[ -n "$_API_PID" ]] && kill "$_API_PID" 2>/dev/null || true
  [[ -n "$_WEB_PID" ]] && kill "$_WEB_PID" 2>/dev/null || true
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

echo "=============================================="
echo "  本地启动: API + Flutter Web 静态 (双进程)"
echo "  HZTECH_LOCAL_WEB_STATIC=1  Web=${WEB_PORT}  API=${API_PORT}  FLASK_DEBUG=${FLASK_DEBUG}  LOG_LEVEL=${LOG_LEVEL}  HZTECH_API_REQUEST_STATS=${HZTECH_API_REQUEST_STATS}"
echo ""
echo "  本机浏览器:"
echo "    Web  http://127.0.0.1:${WEB_PORT}/"
echo "    API  http://127.0.0.1:${API_PORT}/"
echo "  静态目录:"
echo "    ${WEB_ROOT}"
_hztech_echo_mobile_api_urls "$API_PORT"
echo ""
echo "  仅起 API (不要 Web 静态进程):"
echo "    HZTECH_LOCAL_WEB_STATIC=0 $0"
echo "  说明: 计划任务等后台逻辑跑在 API 进程 (端口 ${API_PORT}), Web 进程只提供静态文件"
echo "  停止: Ctrl+C (会结束 API 与 Web 两个进程)"
echo "=============================================="
echo ""

env PORT="$API_PORT" "$_PY" baasapi/main.py &
_API_PID=$!

env HZTECH_WEB_ROOT="$WEB_ROOT" PORT="$WEB_PORT" "$_PY" baasapi/serve_web_static.py &
_WEB_PID=$!

set +e
wait "$_API_PID"
_API_ST=$?
wait "$_WEB_PID"
_WEB_ST=$?
set -e
exit $((_API_ST || _WEB_ST))
