#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HZTECH_MOCK_SCRIPT="$(basename "${BASH_SOURCE[0]}")"
PY="${HZTECH_PYTHON:-python3}"
case "${1:-}" in
  start)
    exec "$PY" "$DIR/mock_bot_ctl.py" start
    ;;
  stop)
    exec "$PY" "$DIR/mock_bot_ctl.py" stop
    ;;
  restart)
    "$PY" "$DIR/mock_bot_ctl.py" stop || true
    exec "$PY" "$DIR/mock_bot_ctl.py" start
    ;;
  checkhealth)
    exec "$PY" "$DIR/mock_bot_ctl.py" checkhealth
    ;;
  status)
    exec "$PY" "$DIR/mock_bot_ctl.py" status
    ;;
  --season)
    case "${2:-}" in
      start)
        exec "$PY" "$DIR/mock_bot_ctl.py" season-start
        ;;
      stop)
        exec "$PY" "$DIR/mock_bot_ctl.py" season-stop
        ;;
      *)
        echo "usage: $0 --season start|stop" >&2
        exit 1
        ;;
    esac
    ;;
  season-start)
    exec "$PY" "$DIR/mock_bot_ctl.py" season-start
    ;;
  season-stop)
    exec "$PY" "$DIR/mock_bot_ctl.py" season-stop
    ;;
  *)
    echo "usage: $0 start|stop|restart|checkhealth|status|--season start|stop|season-start|season-stop" >&2
    exit 1
    ;;
esac
