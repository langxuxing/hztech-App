#!/usr/bin/env bash
# 本地启动：单进程同时提供 REST API（/api/*）与 Flutter Web 静态站（默认端口 8080）
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

PORT="${PORT:-${WEB_PORT:-8080}}"

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

echo "=== 本地启动（API + Flutter Web，端口 $PORT）==="
echo "  【浏览器 / 本机 Web】打开: http://127.0.0.1:$PORT/"
echo "  【手机 App 连本机 API】与浏览器不同 — 127.0.0.1 在手机上指手机自身："
echo "      · Android 模拟器: http://10.0.2.2:$PORT/"
if [[ -n "$_LAN" ]]; then
  echo "      · 真机（同一局域网）: http://${_LAN}:$PORT/"
else
  echo "      · 真机（同一局域网）: http://<电脑局域网IP>:$PORT/"
fi
echo "  App 内「设置」或登录前可填上述地址；路径仍为 /api/..."
echo "  若未执行过 flutter build web，首页会提示构建命令；API 仍可用。"
echo "  按 Ctrl+C 停止"
echo ""

exec env PORT=$PORT python3 server/main.py
