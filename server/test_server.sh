#!/usr/bin/env bash
# 测试远端服务（可指定 BASE_URL，默认从 deploy-aws.json 读取 FlutterApp / BaasAPI 地址）
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
  if [ -f server/deploy-aws.json ]; then
    eval "$(python3 << 'PY'
import json
c = json.load(open("server/deploy-aws.json"))
scheme = c.get("scheme", "http")
web_port = int(c.get("flutter_app_port", c.get("web_port", 9000)))
api_port = int(c.get("baas_api_port", c.get("app_port", web_port)))
fa = c.get("flutter_app") if isinstance(c.get("flutter_app"), dict) else {}
ba = c.get("baas_api") if isinstance(c.get("baas_api"), dict) else {}
if not fa:
    fa = c.get("web") if isinstance(c.get("web"), dict) else {}
if not ba:
    ba = c.get("api") if isinstance(c.get("api"), dict) else {}
if isinstance(fa, dict) and fa.get("host") and isinstance(ba, dict) and ba.get("host"):
    print(f'HOST_URL_WEB="{scheme}://{fa["host"]}:{web_port}"')
    print(f'HOST_URL_API="{scheme}://{ba["host"]}:{api_port}"')
elif isinstance(fa, dict) and fa.get("host"):
    print(f'HOST_URL_WEB="{scheme}://{fa["host"]}:{web_port}"')
    print(f'HOST_URL_API="{scheme}://{fa["host"]}:{api_port}"')
else:
    h = c.get("host", "127.0.0.1")
    print(f'HOST_URL_WEB="{scheme}://{h}:{web_port}"')
    print(f'HOST_URL_API="{scheme}://{h}:{api_port}"')
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

echo "=== 测试: FlutterApp=$HOST_URL_WEB  BaasAPI=$HOST_URL_API ==="

# 超时（秒），可环境变量覆盖
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"
# 1) FlutterApp 静态根
echo -n "GET / (FlutterApp 静态) ... "
code=$(curl -s -o /dev/null -w "%{http_code}" $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" "$HOST_URL_WEB/" || echo "000")
if [ "$code" = "200" ] || [ "$code" = "503" ]; then
  echo "OK ($code)"
else
  echo "FAIL ($code)"; exit 1
fi

echo -n "GET / (BaasAPI JSON) ... "
code=$(curl -s -o /dev/null -w "%{http_code}" $CURL_EXTRA --connect-timeout 5 --max-time "$CURL_TIMEOUT" "$HOST_URL_API/" || echo "000")
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
