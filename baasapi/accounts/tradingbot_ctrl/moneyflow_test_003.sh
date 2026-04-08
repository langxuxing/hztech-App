#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HZTECH_MOCK_SCRIPT="$(basename "${BASH_SOURCE[0]}")"
PY="${HZTECH_PYTHON:-python3}"
_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S"
}
log() { echo "[$(_ts)] [${HZTECH_MOCK_SCRIPT}] $*" >&2; }

case "${1:-}" in
  start)
    log "action=start HZTECH_ACCOUNT_ID=${HZTECH_ACCOUNT_ID:-}"
    exec "$PY" "$DIR/mock_bot_ctl.py" start
    ;;
  stop)
    log "action=stop HZTECH_ACCOUNT_ID=${HZTECH_ACCOUNT_ID:-}"
    exec "$PY" "$DIR/mock_bot_ctl.py" stop
    ;;
  restart)
    log "action=restart HZTECH_ACCOUNT_ID=${HZTECH_ACCOUNT_ID:-}"
    "$PY" "$DIR/mock_bot_ctl.py" stop || true
    exec "$PY" "$DIR/mock_bot_ctl.py" start
    ;;
  checkhealth)
    log "action=checkhealth HZTECH_ACCOUNT_ID=${HZTECH_ACCOUNT_ID:-}"
    exec "$PY" "$DIR/mock_bot_ctl.py" checkhealth
    ;;
  season-start)
    log "action=season-start HZTECH_ACCOUNT_ID=${HZTECH_ACCOUNT_ID:-}"
    exec "$PY" "$DIR/mock_bot_ctl.py" season-start
    ;;
  season-stop)
    log "action=season-stop HZTECH_ACCOUNT_ID=${HZTECH_ACCOUNT_ID:-}"
    exec "$PY" "$DIR/mock_bot_ctl.py" season-stop
    ;;
  *)
    echo "usage: $0 start|stop|restart|checkhealth|season-start|season-stop" >&2
    exit 1
    ;;
esac
