#!/usr/bin/env bash
# 在 AWS EC2 上首次安装服务端依赖并启动（在项目部署目录下执行，如 /home/ec2-user/hztechapp）
# 用法：cd /home/ec2-user/hztechapp && bash aws-ops/code/install_on_aws.sh
# PostgreSQL：库名 hztech、schema flutterapp、用户 hztech（安装/建库见 aws-ops/database/install_postgresql_remote.sh；目录名 hztechapp 非库名）
# 默认：BaasAPI（main.py）+ FlutterApp 静态（flutterapp/web_static/serve_web_static.py）；端口见 deploy-aws.json
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== 安装 AWS 服务端（项目根: $PROJECT_ROOT）==="

# 确保 Python3 与 pip（部分环境 python3 无内置 pip，需用 pip3 或 ensurepip）
if ! command -v python3 &>/dev/null; then
  echo "请先安装 python3（Amazon Linux 2: sudo yum install -y python3 python3-pip）"
  exit 1
fi

if command -v pip3 &>/dev/null; then
  pip3 install --user -r baasapi/requirements.txt -q
elif python3 -c "import pip" &>/dev/null; then
  python3 -m pip install --user -r baasapi/requirements.txt -q
else
  python3 -m ensurepip --user -q 2>/dev/null || true
  python3 -m pip install --user -r baasapi/requirements.txt -q
fi
mkdir -p apk ipa res baasapi/sqlite

API_PORT="${API_PORT:-9001}"
WEB_PORT="${WEB_PORT:-9000}"
WEB_ROOT="${HZTECH_WEB_ROOT:-$PROJECT_ROOT/flutterapp/build/web}"
export MOBILEAPP_ROOT="$PROJECT_ROOT"
# 交易机器人 shell：AWS 上策略脚本目录；生产启停账户列表来自库表 account_list
export HZTECH_TRADINGBOT_CTRL_DIR="${HZTECH_TRADINGBOT_CTRL_DIR:-/home/ec2-user/Alpha}"
export HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE="${HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE:-database}"

# 停止已有进程
pkill -f "baasapi/main.py" 2>/dev/null || true
pkill -f "baasapi/serve_web_static.py" 2>/dev/null || true
pkill -f "flutterapp/web_static/serve_web_static.py" 2>/dev/null || true
pkill -f "baasapi/simpleserver.py" 2>/dev/null || true
sleep 1

echo "启动 API Flask (端口 $API_PORT) ..."
MOBILEAPP_ROOT="$PROJECT_ROOT" PORT=$API_PORT \
  HZTECH_TRADINGBOT_CTRL_DIR="$HZTECH_TRADINGBOT_CTRL_DIR" \
  HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE="$HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE" \
  nohup python3 baasapi/main.py >> server.log 2>&1 &
sleep 1

echo "启动 Web 静态 (端口 $WEB_PORT, HZTECH_WEB_ROOT=$WEB_ROOT) ..."
HZTECH_WEB_ROOT="$WEB_ROOT" PORT=$WEB_PORT nohup python3 flutterapp/web_static/serve_web_static.py >> web_static.log 2>&1 &
sleep 2

if pgrep -f "baasapi/main.py" >/dev/null; then
  IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo 'localhost')
  echo "服务已启动。"
  echo "  API: http://$IP:$API_PORT/  （/api/* 等，日志 tail -f $PROJECT_ROOT/server.log）"
  echo "  Web: http://$IP:$WEB_PORT/  （Flutter Web，日志 tail -f $PROJECT_ROOT/web_static.log）"
else
  echo "API 启动失败，请查看: cat $PROJECT_ROOT/server.log"
  exit 1
fi
