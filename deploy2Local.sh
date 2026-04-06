#!/usr/bin/env bash
# 本地部署：1) 默认同时构建 Flutter Android release APK 与（macOS 上）iOS release IPA，以及 Web
#             2) 启动服务（默认双进程 API 9001 + Web 9000；HZTECH_LOCAL_UNIFIED_PORT=1 时为单进程）
# 依赖：Flutter/Android；IPA 需 macOS + Xcode + 签名；无 AWS/SSH
# 默认：在 macOS 上 APK 与 IPA 均须成功才会启动服务
# 仅 Android：export HZTECH_SKIP_IOS_BUILD=1
# 仅 Web（不构建 APK/iOS）：export HZTECH_SKIP_MOBILE_BUILD=1
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# run_local.sh 默认双进程 API 9001 + Web 9000；若需单进程可 export HZTECH_LOCAL_UNIFIED_PORT=1
export HZTECH_LOCAL_API_PORT="${HZTECH_LOCAL_API_PORT:-${PORT:-9001}}"
export HZTECH_LOCAL_WEB_PORT="${HZTECH_LOCAL_WEB_PORT:-9000}"
# 本地 release 包默认连本机 API（与 ./server/run_local.sh 端口一致）；可覆盖或改用 HZTECH_API_BASE_URL=
export FLUTTER_DART_DEFINE_FILE="${FLUTTER_DART_DEFINE_FILE:-flutter_app/dart_defines/local.json}"

echo "=============================================="
echo "  本地部署：Flutter 构建 → 启动本地服务"
echo "=============================================="

echo ""
_skmb=$(printf '%s' "${HZTECH_SKIP_MOBILE_BUILD:-}" | tr '[:upper:]' '[:lower:]')
if [[ "$_skmb" == "1" || "$_skmb" == "true" || "$_skmb" == "yes" ]]; then
  echo "=== 1/4 跳过 Flutter 移动端（HZTECH_SKIP_MOBILE_BUILD）==="
else
  echo "=== 1/4 构建 Flutter 移动端（默认 release APK + macOS 上 IPA）==="
  python3 "$PROJECT_ROOT/server/server_mgr.py" build
  echo "  APK 输出: $PROJECT_ROOT/apk/"
  echo "  IPA 输出（仅 macOS 成功时）: $PROJECT_ROOT/ipa/"
fi

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
echo "=== 4/4 启动服务（API ${HZTECH_LOCAL_API_PORT} + Web ${HZTECH_LOCAL_WEB_PORT}）==="
echo "  【浏览器 / Flutter Web】http://127.0.0.1:${HZTECH_LOCAL_WEB_PORT}/"
echo "  【手机 App API 基址】勿填 127.0.0.1（在手机上不是电脑）："
echo "      · Android 模拟器: http://10.0.2.2:${HZTECH_LOCAL_API_PORT}/"
if [[ -n "$_LAN" ]]; then
  echo "      · 真机: http://${_LAN}:${HZTECH_LOCAL_API_PORT}/"
else
  echo "      · 真机: http://<本机局域网IP>:${HZTECH_LOCAL_API_PORT}/"
fi
echo "  按 Ctrl+C 停止"
echo "  调试：已开启 FLASK_DEBUG 与 LOG_LEVEL=DEBUG"
echo "=============================================="
export FLASK_DEBUG=1
export LOG_LEVEL=DEBUG
exec "$PROJECT_ROOT/server/run_local.sh"
