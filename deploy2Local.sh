#!/usr/bin/env bash
# 本地部署：1) 构建 Flutter APK 与 Web  2) 启动单进程服务（API + Flutter Web，默认 8080）
# 依赖：Flutter/Android 环境（构建 APK 时需要）；无 AWS/SSH
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

export PORT="${PORT:-${WEB_PORT:-8080}}"
# 本地 release 包默认连本机 API（与 ./server/run_local.sh 端口一致）；可覆盖或改用 HZTECH_API_BASE_URL=
export FLUTTER_DART_DEFINE_FILE="${FLUTTER_DART_DEFINE_FILE:-flutter_app/dart_defines/local.json}"

echo "=============================================="
echo "  本地部署：Flutter 构建 → 启动本地服务"
echo "=============================================="

echo ""
echo "=== 1/4 构建 Flutter App (release APK) ==="
python3 "$PROJECT_ROOT/server/server_mgr.py" build || true
echo "  APK 输出: $PROJECT_ROOT/apk/"

echo ""
echo "=== 2/4 构建 Flutter Web (release) ==="
python3 "$PROJECT_ROOT/server/server_mgr.py" build-web || echo "  （跳过：无 Flutter 或构建失败，仍可提供 API）"

echo ""
echo "=== 3/4 同步本地数据库（用户迁移）==="
cd "$PROJECT_ROOT" && python3 -c "from server.db import init_db; init_db()"
echo "  数据库已同步"

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

echo ""
echo "=== 4/4 启动服务（端口 $PORT：/api/* + /）==="
echo "  【浏览器 / 本机 Web】http://127.0.0.1:${PORT}/"
echo "  【手机 App 后端基址】勿填 127.0.0.1（在手机上不是电脑）："
echo "      · Android 模拟器: http://10.0.2.2:${PORT}/"
if [[ -n "$_LAN" ]]; then
  echo "      · 真机: http://${_LAN}:${PORT}/"
else
  echo "      · 真机: http://<本机局域网IP>:${PORT}/"
fi
echo "  按 Ctrl+C 停止"
echo "  调试：已开启 FLASK_DEBUG 与 LOG_LEVEL=DEBUG"
echo "=============================================="
export FLASK_DEBUG=1
export LOG_LEVEL=DEBUG
exec "$PROJECT_ROOT/server/run_local.sh"
