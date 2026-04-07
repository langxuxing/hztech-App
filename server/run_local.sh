#!/usr/bin/env bash
# 本地启动（默认：仅 API 单进程，与线上 API 节点一致）
#   · API：PORT 默认 9001，python3 server/main.py（/api/*、/kline/*、/download 等）
# 同时起 Flutter Web 静态（本地双进程）：HZTECH_LOCAL_WEB_STATIC=1 ./server/run_local.sh
#   · Web：PORT 默认 9000，python3 server/serve_web_static.py（flutter_app/build/web）
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

API_PORT="${HZTECH_LOCAL_API_PORT:-9001}"
WEB_PORT="${HZTECH_LOCAL_WEB_PORT:-9000}"
# 默认仅 API；与 Flutter Web 联调时 export HZTECH_LOCAL_WEB_STATIC=1
WEB_STATIC="${HZTECH_LOCAL_WEB_STATIC:-0}"
WEB_ROOT="${HZTECH_WEB_ROOT:-$PROJECT_ROOT/flutter_app/build/web}"

if [[ "$WEB_STATIC" != "1" ]]; then
  echo "=== 本地启动（仅 API，端口 $API_PORT）==="
  echo "  【App / 登录 API 基址】http://127.0.0.1:$API_PORT/"
  echo "      · Android 模拟器: http://10.0.2.2:$API_PORT/"
  if [[ -n "$_LAN" ]]; then
    echo "      · 真机: http://${_LAN}:$API_PORT/"
  else
    echo "      · 真机: http://<电脑局域网IP>:$API_PORT/"
  fi
  echo "  同时起 Web 静态（浏览器打开 Flutter Web）：HZTECH_LOCAL_WEB_STATIC=1 $0"
  echo "  按 Ctrl+C 停止"
  echo ""
  exec env PORT="$API_PORT" python3 server/main.py
fi

_API_PID=""
_WEB_PID=""
cleanup() {
  [[ -n "$_API_PID" ]] && kill "$_API_PID" 2>/dev/null || true
  [[ -n "$_WEB_PID" ]] && kill "$_WEB_PID" 2>/dev/null || true
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

echo "=== 本地启动（API $API_PORT + Web 静态 $WEB_PORT）==="
echo "  【浏览器 / Flutter Web】http://127.0.0.1:$WEB_PORT/"
echo "  【App / 登录 API 基址】http://127.0.0.1:$API_PORT/"
echo "  【静态根目录】$WEB_ROOT"
echo "      · Android 模拟器 API: http://10.0.2.2:$API_PORT/"
if [[ -n "$_LAN" ]]; then
  echo "      · 真机 API: http://${_LAN}:$API_PORT/"
else
  echo "      · 真机 API: http://<电脑局域网IP>:$API_PORT/"
fi
echo "  仅 API：去掉 HZTECH_LOCAL_WEB_STATIC 或设 HZTECH_LOCAL_WEB_STATIC=0 $0"
echo "  后台定时任务：仅 API 进程（端口 $API_PORT）"
echo "  按 Ctrl+C 停止两个进程"
echo ""

env PORT="$API_PORT" python3 server/main.py &
_API_PID=$!

env HZTECH_WEB_ROOT="$WEB_ROOT" PORT="$WEB_PORT" python3 server/serve_web_static.py &
_WEB_PID=$!

set +e
wait "$_API_PID"
_API_ST=$?
wait "$_WEB_PID"
_WEB_ST=$?
set -e
exit $((_API_ST || _WEB_ST))
