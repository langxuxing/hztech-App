#!/usr/bin/env bash
# 两台 AWS 服务（baasapi / flutterapp）远程启停与 HTTP 状态探测。
# 配置：baasapi/deploy-aws.json（与 server_mgr 一致）
# 启动 API 时会传入 HZTECH_CORS_ORIGINS（默认同 deploy-aws.json 里 Flutter 公网 URL），避免双机 Web 跨域被浏览器拦截。
#
#   ./ops/aws_ops.sh status [api|web|all]
#   ./ops/aws_ops.sh stop|start|restart [api|web|all]
#
# 说明：停服务用 fuser -k 端口，避免 pkill -f 误杀 ssh 的 bash -c。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
eval "$("$SCRIPT_DIR/read_deploy_config.py" --bash-export-all)"

_ssh_api() {
  ssh -i "$OPS_BAASAPI_SSH_KEY" -p "$OPS_BAASAPI_SSH_PORT" \
    "${OPS_BAASAPI_SSH_OPTS[@]}" \
    "${OPS_BAASAPI_SSH_USER}@${OPS_BAASAPI_SSH_HOST}" "$@"
}

_ssh_web() {
  ssh -i "$OPS_FLUTTER_SSH_KEY" -p "$OPS_FLUTTER_SSH_PORT" \
    "${OPS_FLUTTER_SSH_OPTS[@]}" \
    "${OPS_FLUTTER_SSH_USER}@${OPS_FLUTTER_SSH_HOST}" "$@"
}

# 经 SSH 在远端本机探测 HTTP（公网 curl 超时时用于区分安全组 vs 服务未监听）
_ssh_local_curl_code() {
  local ssh_fn=$1 port=$2 path=$3
  local _qpt _qpath _out
  _qpt=$(printf '%q' "$port")
  _qpath=$(printf '%q' "$path")
  _out=$("$ssh_fn" "PORT=${_qpt}; HP=${_qpath}; export PORT HP; bash -s" <<'R' 2>/dev/null || true
# curl 失败时 -w 仍会输出 000，若再 || echo 000 会拼成 000000
c=$(curl -sS -m 8 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}${HP}" 2>/dev/null || true)
printf '%s' "${c:-000}"
R
  )
  echo "${_out//$'\r'/}" | tr -d '\n' | head -c 16
}

_remote_stop_port() {
  local ssh_fn=$1 port=$2
  local _qpt
  _qpt=$(printf '%q' "$port")
  "$ssh_fn" "PORT=${_qpt}; export PORT; bash -s" <<'R'
fuser -k "${PORT}/tcp" 2>/dev/null || true
R
}

_start_api() {
  local _qrp _qpt _qcors _cors
  _qrp=$(printf '%q' "$OPS_BAASAPI_REMOTE_PATH")
  _qpt=$(printf '%q' "$OPS_BAASAPI_HTTP_PORT")
  # Flutter Web 与 BaasAPI 不同 IP 时为跨域；HTTPS 域名（如 www.sfund.now）见 deploy-aws.json hztech_cors_extra_origins。
  _default_cors="$OPS_FLUTTER_PUBLIC_URL"
  if [[ -n "${OPS_CORS_EXTRA_ORIGINS:-}" ]]; then
    _default_cors="${_default_cors},${OPS_CORS_EXTRA_ORIGINS}"
  fi
  _cors="${HZTECH_CORS_ORIGINS:-$_default_cors}"
  _qcors=$(printf '%q' "$_cors")
  _ssh_api "RPATH=${_qrp}; PORT=${_qpt}; HZTECH_CORS_ORIGINS=${_qcors}; export RPATH PORT HZTECH_CORS_ORIGINS; bash -s" <<'R'
set -euo pipefail
cd "$RPATH"
mkdir -p apk baasapi/sqlite
export HZTECH_TRADINGBOT_CTRL_DIR="${HZTECH_TRADINGBOT_CTRL_DIR:-/home/ec2-user/Alpha}"
export HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE="${HZTECH_TRADINGBOT_ACCOUNT_LIST_SOURCE:-database}"
MOBILEAPP_ROOT="$RPATH" PORT="$PORT" nohup python3 baasapi/main.py >> server.log 2>&1 &
sleep 2
ss -tlnp 2>/dev/null | grep ":${PORT} " || netstat -tlnp 2>/dev/null | grep ":${PORT} " || true
tail -n 8 server.log
R
}

_start_web() {
  local _qrp _qpt
  _qrp=$(printf '%q' "$OPS_FLUTTER_REMOTE_PATH")
  _qpt=$(printf '%q' "$OPS_FLUTTER_HTTP_PORT")
  _ssh_web "RPATH=${_qrp}; PORT=${_qpt}; export RPATH PORT; bash -s" <<'R'
set -euo pipefail
cd "$RPATH"
mkdir -p apk res
rm -rf baasapi/sqlite
HZTECH_WEB_ROOT="$RPATH/flutterapp/build/web" PORT="$PORT" \
  nohup python3 baasapi/serve_web_static.py >> web_static.log 2>&1 &
sleep 2
ss -tlnp 2>/dev/null | grep ":${PORT} " || netstat -tlnp 2>/dev/null | grep ":${PORT} " || true
tail -n 8 web_static.log
R
}

_cmd="${1:-status}"
_tgt="${2:-all}"

case "$_tgt" in
  api | baasapi) _tgt=api ;;
  web | flutter | flutterapp) _tgt=web ;;
  all | both) _tgt=all ;;
  *)
    echo "未知目标: $_tgt （用 api / web / all）" >&2
    exit 2
    ;;
esac

case "$_cmd" in
  status)
    if [[ "$_tgt" == api || "$_tgt" == all ]]; then
      echo "=== BaasAPI ${OPS_BAASAPI_PUBLIC_URL} ==="
      _code=$(curl -sS -m 12 -o /dev/null -w "%{http_code}" \
        "${OPS_BAASAPI_PUBLIC_URL}/api/health" 2>/dev/null) || true
      [[ -z "$_code" ]] && _code=000
      echo "  GET /api/health（公网）→ ${_code}"
      if [[ "$_code" == "000" ]]; then
        echo "  （公网无响应：常见为安全组未放行 TCP ${OPS_BAASAPI_HTTP_PORT}、服务未启动、或公网 IP 已变）"
        _lc=$(_ssh_local_curl_code _ssh_api "$OPS_BAASAPI_HTTP_PORT" "/api/health")
        if [[ -z "$_lc" ]]; then
          echo "  GET /api/health（SSH→本机）→ (无输出，SSH 失败；检查密钥与 ${OPS_BAASAPI_SSH_HOST})"
        else
          echo "  GET /api/health（SSH→本机）→ ${_lc}"
          if [[ "$_lc" == "200" ]]; then
            echo "  → 本机 API 正常：多为安全组/ACL 未对你当前网络开放 ${OPS_BAASAPI_HTTP_PORT}。"
          elif [[ "$_lc" == "000" ]]; then
            echo "  → 本机也未连通：可执行 $0 restart api 或 $0 ssh api 'ss -tlnp | grep :${OPS_BAASAPI_HTTP_PORT} ; tail -n 30 server.log'"
          else
            echo "  → 本机 HTTP 码 ${_lc}，查看: $0 ssh api 'tail -n 50 server.log'"
          fi
        fi
      fi
    fi
    if [[ "$_tgt" == web || "$_tgt" == all ]]; then
      echo "=== Flutter 静态 ${OPS_FLUTTER_PUBLIC_URL} ==="
      _wcode=$(curl -sS -m 12 -o /dev/null -w "%{http_code}" \
        "${OPS_FLUTTER_PUBLIC_URL}/" 2>/dev/null) || true
      [[ -z "$_wcode" ]] && _wcode=000
      echo "  GET /（公网）→ ${_wcode}"
      if [[ "$_wcode" == "000" ]]; then
        _wl=$(_ssh_local_curl_code _ssh_web "$OPS_FLUTTER_HTTP_PORT" "/")
        if [[ -z "$_wl" ]]; then
          echo "  GET /（SSH→本机）→ (无输出，SSH 失败；检查密钥与 ${OPS_FLUTTER_SSH_HOST})"
        else
          echo "  GET /（SSH→本机）→ ${_wl}"
          if [[ "$_wl" == "200" || "$_wl" == "503" ]]; then
            echo "  → 本机 Web 可达（503 可能为未构建）；公网失败多为安全组未放行 ${OPS_FLUTTER_HTTP_PORT}。"
          elif [[ "$_wl" == "000" ]]; then
            echo "  → 本机未监听：可执行 $0 restart web"
          fi
        fi
      fi
    fi
    ;;
  stop)
    if [[ "$_tgt" == api || "$_tgt" == all ]]; then
      echo "=== 停止 BaasAPI :${OPS_BAASAPI_HTTP_PORT} @ ${OPS_BAASAPI_SSH_HOST} ==="
      _remote_stop_port _ssh_api "$OPS_BAASAPI_HTTP_PORT"
    fi
    if [[ "$_tgt" == web || "$_tgt" == all ]]; then
      echo "=== 停止 Flutter 静态 :${OPS_FLUTTER_HTTP_PORT} @ ${OPS_FLUTTER_SSH_HOST} ==="
      _remote_stop_port _ssh_web "$OPS_FLUTTER_HTTP_PORT"
    fi
    ;;
  start)
    if [[ "$_tgt" == api || "$_tgt" == all ]]; then
      echo "=== 启动 BaasAPI @ ${OPS_BAASAPI_SSH_HOST} ==="
      _start_api
    fi
    if [[ "$_tgt" == web || "$_tgt" == all ]]; then
      echo "=== 启动 Flutter 静态 @ ${OPS_FLUTTER_SSH_HOST} ==="
      _start_web
    fi
    ;;
  restart)
    if [[ "$_tgt" == api || "$_tgt" == all ]]; then
      echo "=== 重启 BaasAPI @ ${OPS_BAASAPI_SSH_HOST} ==="
      _remote_stop_port _ssh_api "$OPS_BAASAPI_HTTP_PORT"
      sleep 1
      _start_api
    fi
    if [[ "$_tgt" == web || "$_tgt" == all ]]; then
      echo "=== 重启 Flutter 静态 @ ${OPS_FLUTTER_SSH_HOST} ==="
      _remote_stop_port _ssh_web "$OPS_FLUTTER_HTTP_PORT"
      sleep 1
      _start_web
    fi
    if [[ "$_tgt" == all ]]; then
      echo "=== 合并状态探测 ==="
      "$0" status all
    fi
    ;;
  ssh)
    REST=()
    __i=0
    for __a in "$@"; do
      __i=$((__i + 1))
      if ((__i > 2)); then REST+=("$__a"); fi
    done
    if [[ "$_tgt" == api ]]; then
      _ssh_api "${REST[@]}"
    elif [[ "$_tgt" == web ]]; then
      _ssh_web "${REST[@]}"
    else
      echo "用法: $0 ssh api|web [远程命令...]  例: $0 ssh api 'tail -n 30 server.log'" >&2
      exit 2
    fi
    ;;
  help | -h | --help)
    cat <<'H'
用法: ops/aws_ops.sh <命令> [目标]

命令:
  status          HTTP 探测（默认两台）
  stop|start|restart   经 SSH 在远端停/启/重启进程
  ssh             交互或执行远程命令

目标:
  api|web|all     默认 all；restart all 后会再执行一次 status all

示例:
  ./ops/aws_ops.sh status
  ./ops/aws_ops.sh restart api
  ./ops/aws_ops.sh ssh web 'tail -n 20 web_static.log'
H
    exit 0
    ;;
  *)
    echo "用法: $0 {status|stop|start|restart|ssh|help} [api|web|all]" >&2
    exit 2
    ;;
esac
