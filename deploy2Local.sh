#!/usr/bin/env bash
# 本地一站式：构建 Flutter（移动 + Web）→ 本地 init_db → 启动 run_local.sh
#
# 默认行为（与「本地全栈联调」一致）：
#   · HZTECH_LOCAL_WEB_STATIC=1 → API(9001) + serve_web_static(9000)，与上方 Web 构建配套
#   · 若只要 API（对齐 run_local.sh 默认）：export HZTECH_LOCAL_WEB_STATIC=0
#
# 环境变量：
#   HZTECH_SKIP_MOBILE_BUILD=1  跳过 APK/IPA 构建
#   HZTECH_SKIP_WEB_BUILD=1      跳过 flutter build web
#   HZTECH_SKIP_DB_SYNC=1       跳过本地 init_db
#   HZTECH_LOCAL_API_PORT / HZTECH_LOCAL_WEB_PORT / HZTECH_LOCAL_WEB_STATIC
#   HZTECH_API_BASE_URL / FLUTTER_DART_DEFINE_FILE  传给 Flutter 构建
#   PORT                        与 HZTECH_LOCAL_API_PORT 共用时的回退
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

if ! command -v python3 >/dev/null 2>&1; then
  echo "错误: 需要 python3" >&2
  exit 1
fi

# 默认开启 Web 静态进程，与「已构建 Web」流程一致；仅 API 时显式设为 0
export HZTECH_LOCAL_API_PORT="${HZTECH_LOCAL_API_PORT:-${PORT:-9001}}"
export HZTECH_LOCAL_WEB_PORT="${HZTECH_LOCAL_WEB_PORT:-9000}"
export HZTECH_LOCAL_WEB_STATIC="${HZTECH_LOCAL_WEB_STATIC:-1}"

export HZTECH_API_BASE_URL="${HZTECH_API_BASE_URL:-http://192.168.3.41:9001/}"
export FLUTTER_DART_DEFINE_FILE="${FLUTTER_DART_DEFINE_FILE:-flutter_app/dart_defines/local.json}"

echo "=============================================="
echo "  本地部署：Flutter 构建 → 启动本地服务"
echo "  API 端口: ${HZTECH_LOCAL_API_PORT}  Web 静态: ${HZTECH_LOCAL_WEB_STATIC} (1=双进程)"
echo "=============================================="

_skmb=$(printf '%s' "${HZTECH_SKIP_MOBILE_BUILD:-}" | tr '[:upper:]' '[:lower:]')
if [[ "$_skmb" == "1" || "$_skmb" == "true" || "$_skmb" == "yes" ]]; then
  echo ""
  echo "=== 1/4 跳过 Flutter 移动端（HZTECH_SKIP_MOBILE_BUILD）==="
else
  echo ""
  echo "=== 1/4 构建 Flutter 移动端（release APK + macOS 上 IPA）==="
  python3 "$PROJECT_ROOT/server/server_mgr.py" build
  echo "  APK: $PROJECT_ROOT/apk/"
  echo "  IPA: $PROJECT_ROOT/ipa/"
fi

if [[ "${HZTECH_SKIP_WEB_BUILD:-0}" == "1" ]]; then
  echo ""
  echo "=== 2/4 跳过 Flutter Web（HZTECH_SKIP_WEB_BUILD=1）==="
  if [[ "$HZTECH_LOCAL_WEB_STATIC" == "1" ]] && [[ ! -f "$PROJECT_ROOT/flutter_app/build/web/index.html" ]]; then
    echo "  警告: 未找到 flutter_app/build/web/index.html，Web 静态可能 503。请构建 Web 或关闭 HZTECH_LOCAL_WEB_STATIC。" >&2
  fi
else
  echo ""
  echo "=== 2/4 构建 Flutter Web (release) ==="
  if python3 "$PROJECT_ROOT/server/server_mgr.py" build-web; then
    echo "  Web: $PROJECT_ROOT/flutter_app/build/web/"
  else
    echo "  （Web 构建失败；若 HZTECH_LOCAL_WEB_STATIC=1 则静态站可能不可用）" >&2
  fi
fi

if [[ "${HZTECH_SKIP_DB_SYNC:-0}" != "1" ]]; then
  echo ""
  echo "=== 3/4 同步本地数据库（用户迁移）==="
  python3 -c "from server.db import init_db; init_db()"
  echo "  数据库已就绪"
else
  echo ""
  echo "=== 3/4 跳过本地 DB（HZTECH_SKIP_DB_SYNC=1）==="
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

echo ""
echo "=== 4/4 启动服务 ==="
if [[ "$HZTECH_LOCAL_WEB_STATIC" == "1" ]]; then
  echo "  【浏览器 / Flutter Web】http://127.0.0.1:${HZTECH_LOCAL_WEB_PORT}/"
fi
echo "  【API 基址】http://127.0.0.1:${HZTECH_LOCAL_API_PORT}/"
echo "  【手机 App】模拟器 http://10.0.2.2:${HZTECH_LOCAL_API_PORT}/"
if [[ -n "$_LAN" ]]; then
  echo "            真机 http://${_LAN}:${HZTECH_LOCAL_API_PORT}/"
else
  echo "            真机 http://<本机局域网IP>:${HZTECH_LOCAL_API_PORT}/"
fi
echo "  调试: FLASK_DEBUG=1 LOG_LEVEL=DEBUG"
echo "  仅 API: HZTECH_LOCAL_WEB_STATIC=0 $0"
echo "=============================================="
export FLASK_DEBUG=1
export LOG_LEVEL=DEBUG
exec "$PROJECT_ROOT/server/run_local.sh"
