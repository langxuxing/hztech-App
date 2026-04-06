#!/usr/bin/env bash
# 本地启动（默认与线上一致）：
#   · API 进程：9001，HZTECH_API_ONLY=1（/api/*、/kline/*）
#   · Web 进程：9000，HZTECH_STATIC_ONLY=1（Flutter Web、/download、/res 等）
# 单进程（API+Web 同口）：HZTECH_LOCAL_UNIFIED_PORT=1，端口由 PORT / WEB_PORT（默认 9001）
# 在项目根目录执行：./server/run_local.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# 与当前 `python3` 一致安装依赖（避免系统 Python 未装 PyJWT 导致 ModuleNotFoundError: jwt）
if ! python3 -c "import jwt" 2>/dev/null; then
  echo "检测到当前 python3 未安装 PyJWT 等依赖，正在执行: python3 -m pip install -r server/requirements.txt"
  python3 -m pip install -r "$SCRIPT_DIR/requirements.txt" || exit 1
fi

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

UNIFIED="${HZTECH_LOCAL_UNIFIED_PORT:-0}"
API_PORT="${HZTECH_LOCAL_API_PORT:-9001}"
WEB_PORT="${HZTECH_LOCAL_WEB_PORT:-9000}"

if [[ "$UNIFIED" == "1" ]]; then
  PORT="${PORT:-${WEB_PORT:-9001}}"
  echo "=== 本地启动（单进程 API + Web，端口 $PORT）==="
  echo "  【浏览器 / 本机 Web】http://127.0.0.1:$PORT/"
  echo "  【App API 基址】http://127.0.0.1:$PORT/（与同端口）"
  echo "      · Android 模拟器: http://10.0.2.2:$PORT/"
  if [[ -n "$_LAN" ]]; then
    echo "      · 真机: http://${_LAN}:$PORT/"
  else
    echo "      · 真机: http://<电脑局域网IP>:$PORT/"
  fi
  echo "  按 Ctrl+C 停止"
  echo ""
  exec env PORT="$PORT" python3 server/main.py
fi

_API_PID=""
_WEB_PID=""
cleanup() {
  [[ -n "$_API_PID" ]] && kill "$_API_PID" 2>/dev/null || true
  [[ -n "$_WEB_PID" ]] && kill "$_WEB_PID" 2>/dev/null || true
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

echo "=== 本地启动（API $API_PORT + Web $WEB_PORT，与 AWS 分拆一致）==="
echo "  【浏览器 / Flutter Web】http://127.0.0.1:$WEB_PORT/"
echo "  【App / 登录 API 基址】http://127.0.0.1:$API_PORT/"
echo "      · Android 模拟器 API: http://10.0.2.2:$API_PORT/"
if [[ -n "$_LAN" ]]; then
  echo "      · 真机 API: http://${_LAN}:$API_PORT/"
else
  echo "      · 真机 API: http://<电脑局域网IP>:$API_PORT/"
fi
echo "  单进程模式: HZTECH_LOCAL_UNIFIED_PORT=1 $0"
echo "  按 Ctrl+C 停止两个进程"
echo ""

# 避免 shell 中已 export 的 HZTECH_* 串到另一进程
env HZTECH_STATIC_ONLY= HZTECH_API_ONLY=1 PORT="$API_PORT" python3 server/main.py &
_API_PID=$!

env HZTECH_API_ONLY= HZTECH_STATIC_ONLY=1 PORT="$WEB_PORT" python3 server/main.py &
_WEB_PID=$!

set +e
wait "$_API_PID"
_API_ST=$?
wait "$_WEB_PID"
_WEB_ST=$?
set -e
exit $((_API_ST || _WEB_ST))
