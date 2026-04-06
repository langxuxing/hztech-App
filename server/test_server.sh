#!/usr/bin/env bash
# 测试 AWS 服务端接口（可指定 BASE_URL，默认从 deploy-aws.json 读取）
# 用法：./server/test_server.sh  或  BASE_URL=http://127.0.0.1:9001 ./server/test_server.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -n "$BASE_URL" ]; then
  HOST_URL="$BASE_URL"
  HOST_URL_WEB="$BASE_URL"
  HOST_URL_API="$BASE_URL"
else
  # 从 deploy-aws.json 读取（双机时 Web 与 API 可能不同主机）
  if [ -f server/deploy-aws.json ]; then
    eval "$(python3 << 'PY'
import json
c = json.load(open("server/deploy-aws.json"))
scheme = c.get("scheme", "http")
web_port = int(c.get("web_port", 9000))
api_port = int(c.get("app_port", web_port))
w, a = c.get("web"), c.get("api")
if isinstance(w, dict) and w.get("host") and isinstance(a, dict) and a.get("host"):
    print(f'HOST_URL_WEB="{scheme}://{w["host"]}:{web_port}"')
    print(f'HOST_URL_API="{scheme}://{a["host"]}:{api_port}"')
elif isinstance(w, dict) and w.get("host"):
    u = f'{scheme}://{w["host"]}:{web_port}'
    print(f'HOST_URL_WEB="{u}"')
    print(f'HOST_URL_API="{u}"')
else:
    h = c.get("host", "127.0.0.1")
    u = f"{scheme}://{h}:{api_port}"
    print(f'HOST_URL_WEB="{u}"')
    print(f'HOST_URL_API="{u}"')
PY
)"
    HOST_URL="$HOST_URL_API"
  else
    HOST_URL="http://127.0.0.1:9001"
    HOST_URL_WEB="$HOST_URL"
    HOST_URL_API="$HOST_URL"
  fi
fi
CURL_EXTRA="${CURL_EXTRA:-}"

echo "=== 测试服务端: Web=$HOST_URL_WEB API=$HOST_URL_API ==="

# 超时（秒），可环境变量覆盖
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"
# 1) 首页
echo -n "GET / ... "
code=$(curl -s -o /dev/null -w "%{http_code}" $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" "$HOST_URL_WEB/" || echo "000")
[ "$code" = "200" ] && echo "OK ($code)" || { echo "FAIL ($code)"; exit 1; }

# 2) 策略状态（无需登录）
echo -n "GET /api/strategy/status ... "
code=$(curl -s -o /dev/null -w "%{http_code}" $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" "$HOST_URL_API/api/strategy/status" || echo "000")
[ "$code" = "200" ] && echo "OK ($code)" || { echo "FAIL ($code)"; exit 1; }

# 3) 登录（需已知用户，缺省 admin/i23321，若未配置则跳过断言）
echo -n "POST /api/login ... "
resp=$(curl -s $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" -X POST "$HOST_URL_API/api/login" -H "Content-Type: application/json" -d '{"username":"admin","password":"i23321"}' || echo '{}')
if echo "$resp" | grep -q '"success":true'; then
  echo "OK (login success)"
  TOKEN=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
  if [ -n "$TOKEN" ]; then
    echo -n "GET /api/account-profit (Bearer) ... "
    code=$(curl -s -o /dev/null -w "%{http_code}" $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" -H "Authorization: Bearer $TOKEN" "$HOST_URL_API/api/account-profit" || echo "000")
    [ "$code" = "200" ] && echo "OK ($code)" || echo "FAIL ($code)"
  fi
else
  echo "SKIP (login failed or user not configured)"
fi

echo "=== 测试完成 ==="
