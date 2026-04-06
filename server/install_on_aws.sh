#!/usr/bin/env bash
# 在 AWS EC2 上首次安装服务端依赖并启动（在项目部署目录下执行，如 /home/ec2-user/hztechapp）
# 用法：cd /home/ec2-user/hztechapp && bash server/install_on_aws.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== 安装 AWS 服务端（项目根: $PROJECT_ROOT）==="

# 确保 Python3 与 pip（部分环境 python3 无内置 pip，需用 pip3 或 ensurepip）
if ! command -v python3 &>/dev/null; then
  echo "请先安装 python3（Amazon Linux 2: sudo yum install -y python3 python3-pip）"
  exit 1
fi

if command -v pip3 &>/dev/null; then
  pip3 install --user -r server/requirements.txt -q
elif python3 -c "import pip" &>/dev/null; then
  python3 -m pip install --user -r server/requirements.txt -q
else
  python3 -m ensurepip --user -q 2>/dev/null || true
  python3 -m pip install --user -r server/requirements.txt -q
fi
mkdir -p apk ipa res

# 端口约定：单进程同时提供 Flutter Web + /api/*（与 run_local.sh / deploy-aws.json 的 web_port 一致）
WEB_PORT="${WEB_PORT:-9000}"
export MOBILEAPP_ROOT="$PROJECT_ROOT"

# 停止已有进程
pkill -f "server/main.py" 2>/dev/null || true
pkill -f "server/simpleserver.py" 2>/dev/null || true
sleep 1

echo "启动 Flask (端口 $WEB_PORT：Flutter Web + API) ..."
MOBILEAPP_ROOT="$PROJECT_ROOT" PORT=$WEB_PORT nohup python3 server/main.py >> server.log 2>&1 &
sleep 2

if pgrep -f "server/main.py" >/dev/null; then
  IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo 'localhost')
  echo "服务已启动。"
  echo "  访问: http://$IP:$WEB_PORT  （/api/* 与 Web 同端口）"
  echo "  日志: tail -f $PROJECT_ROOT/server.log"
else
  echo "启动失败，请查看: cat $PROJECT_ROOT/server.log"
  exit 1
fi
