#!/usr/bin/env bash
# 经 SSH 在 aws-alpha（baasapi/deploy-aws.json 中 baasapi）上执行:
#   sudo -u postgres psql -c 'ALTER ROLE <用户> WITH PASSWORD ...'
# 并用新密码做一次 psql 登录校验。
#
# 新密码默认 Alpha（与 database_config.example / db_backend 默认一致）。
# 覆盖请设置: HZTECH_NEW_PG_PASSWORD='你的密码'
# 角色名默认 hztech: HZTECH_PG_USER=hztech
#
# SSH 约定与 ops/pg_verify_aws_alpha.sh 相同。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

NEW_PASS="${HZTECH_NEW_PG_PASSWORD:-Alpha}"
PG_ROLE="${HZTECH_PG_USER:-hztech}"
PASS_B64="$(printf '%s' "$NEW_PASS" | base64 | tr -d '\n')"

# shellcheck disable=SC1090
eval "$("$SCRIPT_DIR/read_deploy_config.py" --bash-export --role baasapi)"

SSH_USER="${OPS_SSH_USER:?}"
SSH_HOST="${OPS_SSH_HOST:?}"
SSH_PORT="${OPS_SSH_PORT:?}"
SSH_KEY="${HZTECH_SSH_KEY_FILE:-$OPS_SSH_KEY}"
SSH_TARGET="${HZTECH_SSH_PG_TARGET:-${SSH_USER}@${SSH_HOST}}"
if [[ -z "${SSH_KEY}" ]]; then
  echo "错误: 未找到 SSH 私钥，请设置 HZTECH_SSH_KEY_FILE 或检查 deploy-aws.json。" >&2
  exit 1
fi

RH="${HZTECH_REMOTE_PG_HOST:-127.0.0.1}"
RP="${HZTECH_REMOTE_PG_PORT:-5432}"
RDB="${HZTECH_REMOTE_PG_DB:-hztech}"

_ssh_base() {
  # shellcheck disable=SC2206
  local _extra=()
  [[ -z "${HZTECH_SSH_OPTS:-}" ]] || _extra=($HZTECH_SSH_OPTS)
  # bash 3.2 + set -u：空数组 "${_extra[@]}" 会报 unbound，需分支。
  if [[ ${#_extra[@]} -gt 0 ]]; then
    ssh "${_extra[@]}" -i "$SSH_KEY" -p "$SSH_PORT" \
      "${OPS_SSH_OPTS[@]}" \
      "$SSH_TARGET" "$@"
  else
    ssh -i "$SSH_KEY" -p "$SSH_PORT" \
      "${OPS_SSH_OPTS[@]}" \
      "$SSH_TARGET" "$@"
  fi
}

echo "=== 设置远端 PostgreSQL 角色密码（SSH: ${SSH_TARGET}, 角色: ${PG_ROLE}）==="
echo "（密码内容不打印；默认与仓库示例一致时为 Alpha）"

_ssh_base env HZTECH_PASS_B64="$PASS_B64" HZTECH_PG_ROLE="$PG_ROLE" \
  RH="$RH" RP="$RP" RDB="$RDB" bash -s <<'REMOTE'
set -euo pipefail
P="$(printf '%s' "$HZTECH_PASS_B64" | base64 -d)"
EP="$(printf '%s' "$P" | sed "s/'/''/g")"
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"${HZTECH_PG_ROLE}\" WITH PASSWORD '${EP}';"
export PGPASSWORD="$P"
psql -v ON_ERROR_STOP=1 -h "$RH" -p "$RP" -U "$HZTECH_PG_ROLE" -d "$RDB" -tAc 'SELECT 1'
REMOTE

echo "=== 完成: 已更新角色 ${PG_ROLE} 的密码并通过 psql 校验 ==="
echo "若 BaasAPI 曾设置 POSTGRES_PASSWORD / DATABASE_URL，请同步为同一密码后重启进程。"
