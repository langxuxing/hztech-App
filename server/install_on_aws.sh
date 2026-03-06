#!/usr/bin/env bash
# 在 AWS EC2 上首次安装服务端依赖并启动（在项目部署目录下执行，如 /home/ec2-user/mobileapp）
# 用法：cd /home/ec2-user/mobileapp && bash server/install_on_aws.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== 安装 AWS 服务端（项目根: $PROJECT_ROOT）==="

# 确保 Python3 与 pip
if ! command -v python3 &>/dev/null; then
  echo "请先安装 python3（Amazon Linux 2: sudo yum install -y python3 python3-pip）"
  exit 1
fi

python3 -m pip install --user -r server/requirements.txt -q
mkdir -p apk res

# 端口约定：Web=9000，API=9001（与 run_local.sh / deploy-aws.json 一致）
WEB_PORT="${WEB_PORT:-9000}"
API_PORT="${API_PORT:-9001}"
export MOBILEAPP_ROOT="$PROJECT_ROOT"

# 停止已有进程
pkill -f "server/app.py" 2>/dev/null || true
pkill -f "server/simpleserver.py" 2>/dev/null || true
sleep 1

echo "启动 Flask 双进程 (Web=$WEB_PORT, API=$API_PORT) ..."
MOBILEAPP_ROOT="$PROJECT_ROOT" PORT=$WEB_PORT nohup python3 server/app.py >> server_web.log 2>&1 &
MOBILEAPP_ROOT="$PROJECT_ROOT" PORT=$API_PORT nohup python3 server/app.py >> server_api.log 2>&1 &
sleep 2

if pgrep -f "server/app.py" >/dev/null; then
  IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo 'localhost')
  echo "服务已启动。"
  echo "  Web: http://$IP:$WEB_PORT"
  echo "  API: http://$IP:$API_PORT"
  echo "  日志: tail -f $PROJECT_ROOT/server_web.log 或 server_api.log"
else
  echo "启动失败，请查看: cat $PROJECT_ROOT/server_web.log server_api.log"
  exit 1
fi
