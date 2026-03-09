#!/usr/bin/env bash
# Ops 一键部署：1) 构建 Flutter APK  2) 同步 webserver + APK 到 AWS  3) 重启 AWS 后台服务
# 依赖：server/deploy-aws.json、本机可 SSH 到 AWS、Flutter/Android 环境
set -e
# 脚本在项目根目录，PROJECT_ROOT = 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

echo "=============================================="
echo "  Ops 部署：Flutter 构建 → AWS 同步 → 服务重启"
echo "=============================================="

echo ""
echo "=== 1/4 构建 Flutter App (release APK) ==="
python3 "$PROJECT_ROOT/server/server_mgr.py" build
echo "  APK 输出: $PROJECT_ROOT/apk/"

echo ""
echo "=== 2/4 上传到 AWS（Web 页面 + 服务端 server/（含 res）+ apk/）==="
python3 "$PROJECT_ROOT/server/server_mgr.py" deploy --no-start
# 仅 rsync 同步，不启动；步骤 3 统一重启服务

echo ""
echo "=== 3/4 同步远程数据库（用户迁移）==="
cd "$PROJECT_ROOT" && python3 server/server_mgr.py db-sync

echo ""
echo "=== 4/4 重启 AWS 后台服务 ==="
cd "$PROJECT_ROOT" && python3 server/server_mgr.py restart

HOST=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); print(c.get('host','54.66.108.150'))")
WEB_PORT=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); print(c.get('web_port',9000))")
API_PORT=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); print(c.get('app_port',9001))")
echo ""
echo "=============================================="
echo "  部署完成"
echo "  Web: http://${HOST}:${WEB_PORT}"
echo "  API: http://${HOST}:${API_PORT}"
echo "  日志: ssh 登录后 cat /home/ec2-user/mobileapp/server_web.log 或 server_api.log"
echo "=============================================="
