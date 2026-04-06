#!/usr/bin/env bash
# Ops 一键部署：1) 构建 Flutter Android APK +（macOS）iOS IPA  2) 同步 webserver + apk/ + ipa/ + Web 到 AWS  3) 重启 AWS 后台服务
# 依赖：server/deploy-aws.json、本机可 SSH 到 AWS、Flutter/Android 环境；IPA 需 macOS + Xcode（失败不阻断，以 APK 成功为准；可 export HZTECH_SKIP_IOS_BUILD=1 跳过 IPA）
#
# 双机 AWS（密钥路径见 server/deploy-aws.json）：
#   API 后端  54.66.108.150  /home/ec2-user/Apiserver   密钥 hztech.pem
#   Web/App   54.252.181.151 /home/ec2-user/hztechapp   密钥 aws-defi.pem
set -e
# 脚本在项目根目录，PROJECT_ROOT = 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"
# AWS 发布包默认连 deploy-aws.json 中的 API 主机；可覆盖 FLUTTER_DART_DEFINE_FILE 或 HZTECH_API_BASE_URL
export FLUTTER_DART_DEFINE_FILE="${FLUTTER_DART_DEFINE_FILE:-flutter_app/dart_defines/production.json}"

echo "=============================================="
echo "  Ops 部署：Flutter 构建 → AWS 同步 → 服务重启"
echo "=============================================="

echo ""
echo "=== 1/5 构建 Flutter 移动端 (release APK + macOS 上 IPA) ==="
python3 "$PROJECT_ROOT/server/server_mgr.py" build
echo "  APK 输出: $PROJECT_ROOT/apk/"
echo "  IPA 输出（仅 macOS 成功时）: $PROJECT_ROOT/ipa/"

echo ""
echo "=== 2/5 构建 Flutter Web (release) ==="
python3 "$PROJECT_ROOT/server/server_mgr.py" build-web || echo "  （跳过 Web 构建）"

echo ""
echo "=== 3/5 上传到 AWS（server/ + apk/ + ipa/ + flutter_app/build/web）==="
python3 "$PROJECT_ROOT/server/server_mgr.py" deploy --no-start
# 仅 rsync 同步，不启动；步骤 3 统一重启服务

echo ""
echo "=== 4/5 同步远程数据库（用户迁移）==="
cd "$PROJECT_ROOT" && python3 server/server_mgr.py db-sync

echo ""
echo "=== 5/5 重启 AWS 后台服务 ==="
cd "$PROJECT_ROOT" && python3 server/server_mgr.py restart

WEB_HOST=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); w=c.get('web') or {}; print(w.get('host') or c.get('host','54.252.181.151'))")
API_HOST=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); a=c.get('api') or {}; print(a.get('host',''))")
WEB_PORT=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); print(c.get('web_port',9000))")
WEB_KEY=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); w=c.get('web') or {}; print(w.get('key') or c.get('key',''))")
API_KEY=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); a=c.get('api') or {}; print(a.get('key') or c.get('key',''))")
WEB_USER=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); print(c.get('user','ec2-user'))")
echo ""
echo "=============================================="
echo "  部署完成（双机：API 与 Web 分离）"
echo "  Web/App（Flutter Web + apk/ + ipa/）: http://${WEB_HOST}:${WEB_PORT}"
if [ -n "$API_HOST" ]; then
  echo "  API（/api/*）: http://${API_HOST}:${WEB_PORT}"
  echo "  日志 Web: ssh -i \"${WEB_KEY}\" ${WEB_USER}@${WEB_HOST} cat /home/ec2-user/hztechapp/server.log"
  echo "  日志 API: ssh -i \"${API_KEY}\" ${WEB_USER}@${API_HOST} cat /home/ec2-user/Apiserver/server.log"
else
  echo "  访问: http://${WEB_HOST}:${WEB_PORT}"
  echo "  日志: ssh -i \"${WEB_KEY}\" ${WEB_USER}@${WEB_HOST} cat /home/ec2-user/hztechapp/server.log"
fi
echo "=============================================="
