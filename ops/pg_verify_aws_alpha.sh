#!/usr/bin/env bash
# 经 SSH 在 aws-alpha（baasapi/deploy-aws.json 中 baasapi）上连接本机 PostgreSQL，执行只读检查：
#   select now()、版本、各 schema 用户表数量（排除系统 schema）。
#
# 依赖：远端已安装 psql（PostgreSQL 服务端自带）；本机仅需 ssh。
#
# 用法：
#   ./ops/pg_verify_aws_alpha.sh
#   HZTECH_REMOTE_PG_PASSWORD='...' ./ops/pg_verify_aws_alpha.sh
#
# 与 pg_dump_to_aws_alpha.sh 相同的 SSH / 远端连接环境变量（HZTECH_SSH_PG_TARGET、HZTECH_REMOTE_PG_* 等）。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# shellcheck disable=SC1090
eval "$("$SCRIPT_DIR/read_deploy_config.py" --bash-export --role baasapi)"

SSH_USER="${OPS_SSH_USER:?}"
SSH_HOST="${OPS_SSH_HOST:?}"
SSH_PORT="${OPS_SSH_PORT:?}"
SSH_KEY="${HZTECH_SSH_KEY_FILE:-$OPS_SSH_KEY}"
SSH_TARGET="${HZTECH_SSH_PG_TARGET:-${SSH_USER}@${SSH_HOST}}"
if [[ -z "${SSH_KEY}" ]]; then
  echo "错误: 未找到 SSH 私钥，请设置 HZTECH_SSH_KEY_FILE 或检查 baasapi/deploy-aws.json 中 baasapi.key。" >&2
  exit 1
fi

RH="${HZTECH_REMOTE_PG_HOST:-127.0.0.1}"
RP="${HZTECH_REMOTE_PG_PORT:-5432}"
RDB="${HZTECH_REMOTE_PG_DB:-hztech}"
RU="${HZTECH_REMOTE_PG_USER:-hztech}"
SCHEMA="${HZTECH_POSTGRES_SCHEMA:-flutterapp}"

_remote_pw() {
  printf '%s' "${HZTECH_REMOTE_PG_PASSWORD:-${POSTGRES_PASSWORD:-Alpha}}"
}

_ssh_base() {
  # shellcheck disable=SC2206
  local _extra=()
  [[ -z "${HZTECH_SSH_OPTS:-}" ]] || _extra=($HZTECH_SSH_OPTS)
  ssh "${_extra[@]}" -i "$SSH_KEY" -p "$SSH_PORT" \
    "${OPS_SSH_OPTS[@]}" \
    "$SSH_TARGET" "$@"
}

echo "=== aws-alpha PostgreSQL 验证（SSH: ${SSH_TARGET}, db: ${RDB}）==="

_ssh_base env PGPASSWORD="$(_remote_pw)" \
  psql -v ON_ERROR_STOP=1 -h "$RH" -p "$RP" -U "$RU" -d "$RDB" \
  -c "select now() as server_time, current_database() as db, current_user as role;" \
  -c "select version();" \
  -c "SELECT nspname AS schema, count(*)::int AS user_tables
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog','information_schema')
      GROUP BY n.nspname
      ORDER BY 1;" \
  -c "SELECT count(*)::int AS tables_in_${SCHEMA}
      FROM information_schema.tables
      WHERE table_schema = '$SCHEMA' AND table_type = 'BASE TABLE';"

echo "=== 完成 ==="
