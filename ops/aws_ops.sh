#!/usr/bin/env bash
# 两台 AWS 服务（baasapi / flutterapp）远程启停与 HTTP 状态探测。
# 配置：baasapi/deploy-aws.json（与 server_mgr 一致）
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

_remote_stop_port() {
  local ssh_fn=$1 port=$2
  local _qpt
  _qpt=$(printf '%q' "$port")
  "$ssh_fn" "PORT=${_qpt}; export PORT; bash -s" <<'R'
fuser -k "${PORT}/tcp" 2>/dev/null || true
R
}

_start_api() {
  local _qrp _qpt
  _qrp=$(printf '%q' "$OPS_BAASAPI_REMOTE_PATH")
  _qpt=$(printf '%q' "$OPS_BAASAPI_HTTP_PORT")
  _ssh_api "RPATH=${_qrp}; PORT=${_qpt}; export RPATH PORT; bash -s" <<'R'
set -euo pipefail
cd "$RPATH"
mkdir -p apk baasapi/sqlite
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
      curl -sS -m 12 -o /dev/null -w "  GET /api/health → %{http_code}\n" \
        "${OPS_BAASAPI_PUBLIC_URL}/api/health" || echo "  (请求失败)"
    fi
    if [[ "$_tgt" == web || "$_tgt" == all ]]; then
      echo "=== Flutter 静态 ${OPS_FLUTTER_PUBLIC_URL} ==="
      curl -sS -m 12 -o /dev/null -w "  GET / → %{http_code}\n" \
        "${OPS_FLUTTER_PUBLIC_URL}/" || echo "  (请求失败)"
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
