#!/usr/bin/env bash
# 本地启动：Web 端口 9000，API 端口 9001（非 AWS）
# 在项目根目录执行：./server/run_local.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

WEB_PORT="${WEB_PORT:-9000}"
API_PORT="${API_PORT:-9001}"

# 若只测 API（如 App 联调），可只起 API：API_ONLY=1 ./server/run_local.sh
if [ "${API_ONLY}" = "1" ]; then
  echo "=== 本地仅启动 API（端口 $API_PORT）==="
  echo "  API: http://127.0.0.1:$API_PORT  （App 后端地址设为此处）"
  exec env PORT=$API_PORT python3 server/app.py
fi

cleanup() {
  echo ""
  echo "正在停止服务..."
  kill $(jobs -p) 2>/dev/null || true
  exit 0
}
trap cleanup SIGINT SIGTERM

echo "=== 本地启动（Web=$WEB_PORT, API=$API_PORT）==="
echo "  Web:  http://127.0.0.1:$WEB_PORT"
echo "  API:  http://127.0.0.1:$API_PORT  （App 调试请将后端地址设为此处）"
echo "  按 Ctrl+C 停止"
echo ""

PORT=$API_PORT python3 server/app.py &
PORT=$WEB_PORT python3 server/app.py &

wait
