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

# 与当前 python3 一致安装依赖（与 deploy2Local 共用 install_python_deps.sh）
case "${HZTECH_SKIP_PIP_INSTALL:-}" in
1 | true | yes) ;;
*)
  if ! python3 -c "import flask, jwt, requests, ccxt" 2>/dev/null; then
    echo "检测到缺少 BaasAPI 运行时依赖，正在安装 baasapi/requirements.txt ..."
    "$SCRIPT_DIR/install_python_deps.sh" || exit 1
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
  echo "  HZTECH_LOCAL_WEB_STATIC=${WEB_STATIC}  FLASK_DEBUG=${FLASK_DEBUG:-0}  LOG_LEVEL=${LOG_LEVEL:-}"
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
  exec env PORT="$API_PORT" python3 baasapi/main.py
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
echo "  HZTECH_LOCAL_WEB_STATIC=1  Web=${WEB_PORT}  API=${API_PORT}  FLASK_DEBUG=${FLASK_DEBUG:-0}  LOG_LEVEL=${LOG_LEVEL:-}"
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

env PORT="$API_PORT" python3 baasapi/main.py &
_API_PID=$!

env HZTECH_WEB_ROOT="$WEB_ROOT" PORT="$WEB_PORT" python3 baasapi/serve_web_static.py &
_WEB_PID=$!

set +e
wait "$_API_PID"
_API_ST=$?
wait "$_WEB_PID"
_WEB_ST=$?
set -e
exit $((_API_ST || _WEB_ST))
