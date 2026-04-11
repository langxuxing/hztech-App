#!/usr/bin/env bash
# 交易机器人管控（统一约定）：
#   start|stop|restart  — 写 tradingbot.log 后再调 mock_bot_ctl（PID 由 mock 侧）
#   status              — 仅 stdout 输出一行：running 或 stopped（不写日志）
#   logs                — tail -n 100 tradingbot.log（不写新记录）
#   --season start|stop — 仅写日志「赛季启动/赛季停止」，不写 .season_cmd
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HZTECH_MOCK_SCRIPT="$(basename "${BASH_SOURCE[0]}")"
PY="${HZTECH_PYTHON:-python3}"
LOG_FILE="${HZTECH_TRADINGBOT_CTRL_LOG:-$DIR/tradingbot.log}"

# 追加一行日志（UTC 时间戳 + TradingBotCtrl + 文案；可选 account_id）
_log_ctrl() {
  local ts msg
  msg=$1
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"
  {
    printf '%s TradingBotCtrl %s' "$ts" "$msg"
    if [ -n "${HZTECH_ACCOUNT_ID:-}" ]; then
      printf ' account_id=%s' "${HZTECH_ACCOUNT_ID}"
    fi
    printf '\n'
  } >>"$LOG_FILE"
}

# 根据 mock_bot_ctl status 的 JSON 输出一行 running / stopped
_status_word() {
  if ! "$PY" "$DIR/mock_bot_ctl.py" status 2>/dev/null |
    "$PY" -c 'import sys,json
try:
    d = json.load(sys.stdin)
    print("running" if d.get("running") else "stopped")
except Exception:
    print("stopped")'; then
    echo stopped
  fi
}

_season_log_only() {
  case "${1:-}" in
    start) _log_ctrl "赛季启动" ;;
    stop) _log_ctrl "赛季停止" ;;
    *)
      echo "usage: $0 --season start|stop" >&2
      exit 1
      ;;
  esac
  exit 0
}

case "${1:-}" in
  start)
    _log_ctrl "启动"
    exec "$PY" "$DIR/mock_bot_ctl.py" start
    ;;
  stop)
    _log_ctrl "停止"
    exec "$PY" "$DIR/mock_bot_ctl.py" stop
    ;;
  restart)
    _log_ctrl "重启"
    "$PY" "$DIR/mock_bot_ctl.py" stop || true
    exec "$PY" "$DIR/mock_bot_ctl.py" start
    ;;
  status)
    _status_word
    ;;
  logs)
    if [ ! -f "$LOG_FILE" ]; then
      echo "(无日志文件: $LOG_FILE)" >&2
      exit 0
    fi
    tail -n 100 "$LOG_FILE"
    ;;
  checkhealth)
    exec "$PY" "$DIR/mock_bot_ctl.py" checkhealth
    ;;
  --season)
    _season_log_only "${2:-}"
    ;;
  season-start)
    _log_ctrl "赛季启动"
    exit 0
    ;;
  season-stop)
    _log_ctrl "赛季停止"
    exit 0
    ;;
  *)
    echo "usage: $0 start|stop|restart|status|logs|--season start|stop|season-start|season-stop" >&2
    exit 1
    ;;
esac
