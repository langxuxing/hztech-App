#!/usr/bin/env bash
# 使用 PostgreSQL 跑 pytest（HZTECH_DB_PROFILE=test，库需已存在，如 hztech）。
# 用法（在项目根）:
#   export DATABASE_URL='postgresql://用户:密码@127.0.0.1:5432/hztech'
#   ./test/run_pgtest.sh
# 或:
#   ./test/run_pgtest.sh -q test/test_api.py
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export HZTECH_DB_PROFILE="${HZTECH_DB_PROFILE:-test}"
export PYTEST_DISABLE_PLUGIN_AUTOLOAD="${PYTEST_DISABLE_PLUGIN_AUTOLOAD:-1}"
if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "请设置 DATABASE_URL，例如: export DATABASE_URL='postgresql://用户@127.0.0.1:5432/hztech'" >&2
  exit 2
fi
exec python3 -m pytest test "$@"
