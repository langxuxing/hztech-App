#!/usr/bin/env bash
# 测试 AWS 服务端接口（可指定 BASE_URL，默认从 deploy-aws.json 读取）
# 用法：./server/test_server.sh  或  BASE_URL=http://1.2.3.4:9001 ./server/test_server.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -n "$BASE_URL" ]; then
  HOST_URL="$BASE_URL"
else
  # 从 deploy-aws.json 读取（当前服务端为 HTTP；若已配置 nginx 等 HTTPS 可改 scheme 为 https）
  if [ -f server/deploy-aws.json ]; then
    SCHEME=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); print(c.get('scheme','http'))")
    APP_PORT=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); print(c.get('app_port', 9001))")
    HOST=$(python3 -c "import json; c=json.load(open('server/deploy-aws.json')); print(c['host'])")
    HOST_URL="${SCHEME}://${HOST}:${APP_PORT}"
  else
    HOST_URL="http://127.0.0.1:9001"
  fi
fi
CURL_EXTRA="${CURL_EXTRA:-}"

echo "=== 测试服务端: $HOST_URL ==="

# 超时（秒），可环境变量覆盖
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"
# 1) 首页
echo -n "GET / ... "
code=$(curl -s -o /dev/null -w "%{http_code}" $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" "$HOST_URL/" || echo "000")
[ "$code" = "200" ] && echo "OK ($code)" || { echo "FAIL ($code)"; exit 1; }

# 2) 策略状态（无需登录）
echo -n "GET /api/strategy/status ... "
code=$(curl -s -o /dev/null -w "%{http_code}" $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" "$HOST_URL/api/strategy/status" || echo "000")
[ "$code" = "200" ] && echo "OK ($code)" || { echo "FAIL ($code)"; exit 1; }

# 3) 登录（需已知用户，admin/123 为常见测试账号，若未配置则跳过断言）
echo -n "POST /api/login ... "
resp=$(curl -s $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" -X POST "$HOST_URL/api/login" -H "Content-Type: application/json" -d '{"username":"admin","password":"123"}' || echo '{}')
if echo "$resp" | grep -q '"success":true'; then
  echo "OK (login success)"
  TOKEN=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
  if [ -n "$TOKEN" ]; then
    echo -n "GET /api/account-profit (Bearer) ... "
    code=$(curl -s -o /dev/null -w "%{http_code}" $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" -H "Authorization: Bearer $TOKEN" "$HOST_URL/api/account-profit" || echo "000")
    [ "$code" = "200" ] && echo "OK ($code)" || echo "FAIL ($code)"
  fi
else
  echo "SKIP (login failed or user not configured)"
fi

echo "=== 测试完成 ==="
