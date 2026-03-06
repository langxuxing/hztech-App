#!/usr/bin/env bash
# 本地部署（方便测试）：1) 构建 Flutter APK  2) 启动本地 Web + API 服务（端口 9000/9001）
# 依赖：Flutter/Android 环境（仅构建 APK 时需要）；无 AWS/SSH
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

WEB_PORT="${WEB_PORT:-9000}"
API_PORT="${API_PORT:-9001}"

echo "=============================================="
echo "  本地部署：Flutter 构建 → 启动本地服务"
echo "=============================================="

echo ""
echo "=== 1/2 构建 Flutter App (release APK) ==="
python3 "$PROJECT_ROOT/server/server_mgr.py" build
echo "  APK 输出: $PROJECT_ROOT/apk/"

echo ""
echo "=== 2/2 启动本地服务（Web=$WEB_PORT, API=$API_PORT）==="
echo "  Web:  http://127.0.0.1:${WEB_PORT}"
echo "  API:  http://127.0.0.1:${API_PORT}  （App 调试请将后端地址设为此处）"
echo "  按 Ctrl+C 停止"
echo "=============================================="
exec "$PROJECT_ROOT/server/run_local.sh"
