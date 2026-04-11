#!/usr/bin/env bash
# 将本地 PostgreSQL 备份并导入 aws-alpha（baasapi/deploy-aws.json 中 baasapi 段，即 BaasAPI EC2）。
# 远端库仅监听 127.0.0.1:5432（见 baasapi/install_postgresql_remote.sh），故通过 SSH 管道执行 psql。
#
# 统一入口：./ops/gp_ops.sh dump-alpha（本文件为纯 bash 实现，功能与 pg_ows_import 重叠时可任选其一）。
# 依赖：本机已安装 pg_dump；ssh 可登录目标机；远端已创建目标库与用户。
# 数据迁移推荐：./ops/gp_ops.sh 或 python3 ops/pg_ows_import.py
#
# 用法：
#   ./ops/pg_dump_to_aws_alpha.sh
#   ./ops/pg_dump_to_aws_alpha.sh --dry-run
#   ./ops/pg_dump_to_aws_alpha.sh --backup-remote-first
#
# EC2 部署目录名也常为 hztechapp（remote_path）；PostgreSQL 库名一般为 hztech。
# 仅导出单个应用 schema（默认与 database_config 的 postgres_schema 一致，一般为 flutterapp；EC2 目录名 hztechapp 不是 schema）：
#   HZTECH_PG_DUMP_APP_ONLY=1 ./ops/pg_dump_to_aws_alpha.sh
# 若库中应用 schema 仍为 flutterapp：HZTECH_APP_PG_SCHEMA=flutterapp HZTECH_PG_DUMP_APP_ONLY=1 …
# 多 schema（如 public + flutterapp）用空格分隔（与 pg_ows_import 的 HZTECH_PG_DUMP_SCHEMAS 一致）：
#   HZTECH_PG_DUMP_SCHEMAS="public flutterapp" ./ops/pg_dump_to_aws_alpha.sh
#
# 本地连接（与 baasapi/db_backend.py 一致，任选）：
#   DATABASE_URL=postgresql://...
#   或 POSTGRES_HOST / POSTGRES_PORT / POSTGRES_DB / POSTGRES_USER / POSTGRES_PASSWORD
#
# 远端连接（默认与 install_postgresql_remote 一致）：
#   HZTECH_REMOTE_PG_HOST=127.0.0.1  HZTECH_REMOTE_PG_PORT=5432
#   HZTECH_REMOTE_PG_USER=hztech  HZTECH_REMOTE_PG_DB=hztech  HZTECH_REMOTE_PG_PASSWORD=...
#
# SSH（可选覆盖 deploy-aws.json）：
#   HZTECH_SSH_PG_TARGET=ec2-user@54.66.108.150
#   HZTECH_SSH_KEY_FILE=/path/to.pem
#   HZTECH_SSH_OPTS='-o StrictHostKeyChecking=accept-new'
#
# 可选：导入前把本地 dump 另存一份（便于留档）：
#   HZTECH_LOCAL_DUMP_COPY="$PROJECT_ROOT/.temp-cursor/local_hztech_before_aws_import.sql"
#
# 全库 pg_dump 时默认排除 schema QTrader（与其它 schema 一并写在 HZTECH_PG_DUMP_EXCLUDE_SCHEMAS）；
# 若仍要导出 QTrader：HZTECH_PG_DUMP_INCLUDE_QTRADER=1
# 额外排除（空格分隔）：HZTECH_PG_DUMP_EXCLUDE_SCHEMAS='other_schema'
# 若在无默认排除时仍报 QTrader 权限错误，可在源库 GRANT USAGE/SELECT ON SCHEMA "QTrader" …
#
# 导入后验证（远端 psql）：ops/pg_verify_aws_alpha.sh（与本脚本同目录）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

DRY_RUN=0
BACKUP_REMOTE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run)
    DRY_RUN=1
    shift
    ;;
  --backup-remote-first)
    BACKUP_REMOTE=1
    shift
    ;;
  -h | --help)
    sed -n '1,55p' "$0"
    exit 0
    ;;
  *)
    echo "未知参数: $1 （--dry-run / --backup-remote-first / -h）" >&2
    exit 2
    ;;
  esac
done

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

_remote_pw() {
  printf '%s' "${HZTECH_REMOTE_PG_PASSWORD:-${POSTGRES_PASSWORD:-Alpha}}"
}

_local_dump_args() {
  # --clean --if-exists：导入时会先 DROP 再建（覆盖远端同名字段/表）
  # --no-owner --no-acl：避免本机角色名与远端不一致导致失败
  local _args=(--format=p --no-owner --no-acl --clean --if-exists)
  local _schemas="${HZTECH_PG_DUMP_SCHEMAS:-}"
  if [[ -z "${_schemas}" ]]; then
    case "${HZTECH_PG_DUMP_APP_ONLY:-}" in
    1 | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee]) _schemas="${HZTECH_APP_PG_SCHEMA:-${HZTECH_POSTGRES_SCHEMA:-flutterapp}}" ;;
    esac
  fi
  if [[ -n "${_schemas}" ]]; then
    local _s
    for _s in ${_schemas}; do
      [[ -z "${_s}" ]] && continue
      _args+=(--schema="${_s}")
    done
  fi
  local _has_qt_ex=0
  if [[ -n "${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS:-}" ]]; then
    local _s
    for _s in ${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS}; do
      [[ "${_s}" == "QTrader" ]] && _has_qt_ex=1
    done
  fi
  # 未指定 --schema 列表时默认去掉 QTrader，避免无权限或不需要迁移该 schema
  if [[ -z "${_schemas}" ]]; then
    case "${HZTECH_PG_DUMP_INCLUDE_QTRADER:-}" in
    1 | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee]) ;;
    *) [[ "${_has_qt_ex}" == "1" ]] || _args+=(--exclude-schema=QTrader) ;;
    esac
  fi
  if [[ -n "${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS:-}" ]]; then
    local _s
    for _s in ${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS}; do
      [[ -z "${_s}" ]] && continue
      _args+=(--exclude-schema="${_s}")
    done
  fi
  local _url="${DATABASE_URL:-}"
  if [[ -n "$_url" ]]; then
    echo "${_args[@]}" -- "$_url"
    return
  fi
  local _h="${POSTGRES_HOST:-localhost}"
  local _p="${POSTGRES_PORT:-5432}"
  local _d="${POSTGRES_DB:-hztech}"
  local _u="${POSTGRES_USER:-hztech}"
  echo "${_args[@]}" -h "$_h" -p "$_p" -U "$_u" -d "$_d"
}

_run_local_pg_dump() {
  if [[ -n "${DATABASE_URL:-}" ]]; then
    # shellcheck disable=SC2046
    pg_dump $(_local_dump_args)
  else
    # shellcheck disable=SC2046
    PGPASSWORD="${POSTGRES_PASSWORD:-Alpha}" pg_dump $(_local_dump_args)
  fi
}

_ssh_base() {
  # shellcheck disable=SC2206
  local _extra=()
  [[ -z "${HZTECH_SSH_OPTS:-}" ]] || _extra=($HZTECH_SSH_OPTS)
  ssh "${_extra[@]}" -i "$SSH_KEY" -p "$SSH_PORT" \
    "${OPS_SSH_OPTS[@]}" \
    "$SSH_TARGET" "$@"
}

echo "=== 本地 → aws-alpha PostgreSQL 导入 ==="
echo "  SSH: ${SSH_TARGET} (key: ${SSH_KEY})"
if [[ -n "${DATABASE_URL:-}" ]]; then
  echo "  本地: DATABASE_URL（已设置）"
else
  echo "  本地: ${POSTGRES_HOST:-localhost}:${POSTGRES_PORT:-5432} db=${POSTGRES_DB:-hztech} user=${POSTGRES_USER:-hztech}"
fi
echo "  远端: ${RH}:${RP} db=${RDB} user=${RU}"
if [[ -n "${HZTECH_PG_DUMP_SCHEMAS:-}" ]]; then
  echo "  pg_dump: 仅 schema（HZTECH_PG_DUMP_SCHEMAS）: ${HZTECH_PG_DUMP_SCHEMAS}"
else
  case "${HZTECH_PG_DUMP_APP_ONLY:-}" in
  1 | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee])
    echo "  pg_dump: 仅 schema ${HZTECH_APP_PG_SCHEMA:-${HZTECH_POSTGRES_SCHEMA:-flutterapp}}（HZTECH_PG_DUMP_APP_ONLY）"
    ;;
  *)
    if [[ -n "${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS:-}" ]]; then
      case "${HZTECH_PG_DUMP_INCLUDE_QTRADER:-}" in
      1 | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee])
        echo "  pg_dump: 排除 schema（HZTECH_PG_DUMP_EXCLUDE_SCHEMAS）: ${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS}"
        ;;
      *)
        echo "  pg_dump: 排除 schema: QTrader（默认） + ${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS}"
        ;;
      esac
    else
      case "${HZTECH_PG_DUMP_INCLUDE_QTRADER:-}" in
      1 | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee])
        echo "  pg_dump: 全库（HZTECH_PG_DUMP_INCLUDE_QTRADER，含 QTrader）"
        ;;
      *)
        echo "  pg_dump: 全库，默认排除 QTrader"
        ;;
      esac
    fi
    ;;
  esac
fi

if ! command -v pg_dump >/dev/null 2>&1; then
  echo "错误: 未找到 pg_dump，请安装 PostgreSQL 客户端（例如 brew install libpq && brew link --force libpq）。" >&2
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] 将执行（示意）:"
  echo "  pg_dump $(_local_dump_args | tr '\n' ' ')"
  echo "  | ssh ... env PGPASSWORD=*** + 远端 PGHOST=$RH ... psql -v ON_ERROR_STOP=1"
  exit 0
fi

mkdir -p "$PROJECT_ROOT/.temp-cursor"

if [[ "$BACKUP_REMOTE" == "1" ]]; then
  _snap="$PROJECT_ROOT/.temp-cursor/aws_alpha_before_import_$(date +%Y%m%d_%H%M%S).sql"
  echo "=== 先备份远端当前库到: $_snap ==="
  _ssh_base env PGPASSWORD="$(_remote_pw)" \
    HZTECH_PG_DUMP_EXCLUDE_SCHEMAS="${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS:-}" \
    HZTECH_PG_DUMP_SCHEMAS="${HZTECH_PG_DUMP_SCHEMAS:-}" \
    HZTECH_PG_DUMP_APP_ONLY="${HZTECH_PG_DUMP_APP_ONLY:-}" \
    HZTECH_APP_PG_SCHEMA="${HZTECH_APP_PG_SCHEMA:-}" \
    HZTECH_PG_DUMP_INCLUDE_QTRADER="${HZTECH_PG_DUMP_INCLUDE_QTRADER:-}" \
    RH="$RH" RP="$RP" RU="$RU" RDB="$RDB" \
    bash -s <<'REMOTE' > "$_snap"
set -euo pipefail
command -v pg_dump >/dev/null 2>&1 || { echo "远端未安装 pg_dump，请先安装 postgresql*-contrib 或去掉 --backup-remote-first" >&2; exit 1; }
_remote_in=()
_schemas="${HZTECH_PG_DUMP_SCHEMAS:-}"
if [[ -z "${_schemas}" ]]; then
  case "${HZTECH_PG_DUMP_APP_ONLY:-}" in
  1 | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee]) _schemas="${HZTECH_APP_PG_SCHEMA:-${HZTECH_POSTGRES_SCHEMA:-flutterapp}}" ;;
  esac
fi
if [[ -n "${_schemas}" ]]; then
  for _s in ${_schemas}; do
    [[ -z "${_s}" ]] && continue
    _remote_in+=(--schema="${_s}")
  done
fi
_remote_ex=()
_has_qt_ex=0
if [[ -n "${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS:-}" ]]; then
  for _s in ${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS}; do
    [[ "${_s}" == "QTrader" ]] && _has_qt_ex=1
  done
fi
if [[ -z "${_schemas}" ]]; then
  case "${HZTECH_PG_DUMP_INCLUDE_QTRADER:-}" in
  1 | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee]) ;;
  *) [[ "${_has_qt_ex}" == "1" ]] || _remote_ex+=(--exclude-schema=QTrader) ;;
  esac
fi
if [[ -n "${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS:-}" ]]; then
  for _s in ${HZTECH_PG_DUMP_EXCLUDE_SCHEMAS}; do
    [[ -z "${_s}" ]] && continue
    _remote_ex+=(--exclude-schema="${_s}")
  done
fi
pg_dump --format=p --no-owner --no-acl "${_remote_in[@]}" "${_remote_ex[@]}" -h "$RH" -p "$RP" -U "$RU" -d "$RDB"
REMOTE
  echo "  已写入 $_snap"
fi

if [[ -n "${HZTECH_LOCAL_DUMP_COPY:-}" ]]; then
  echo "=== 另存本地 dump 到: $HZTECH_LOCAL_DUMP_COPY ==="
  mkdir -p "$(dirname "$HZTECH_LOCAL_DUMP_COPY")"
  _run_local_pg_dump >"$HZTECH_LOCAL_DUMP_COPY"
fi

echo "=== pg_dump（本地）| psql（远端），开始 ==="
# 注意：不得用 bash -s 从 heredoc 读远程脚本，否则占用 SSH stdin，无法接收管道中的 dump。
set +o pipefail
set +e
_run_local_pg_dump | _ssh_base env PGPASSWORD="$(_remote_pw)" \
  psql -v ON_ERROR_STOP=1 -h "$RH" -p "$RP" -U "$RU" -d "$RDB"
_dump_rc="${PIPESTATUS[0]}"
_psql_rc="${PIPESTATUS[1]}"
set -e
set -o pipefail
if [[ "$_dump_rc" != "0" ]]; then
  echo "错误: 本地 pg_dump 失败（退出码 $_dump_rc）" >&2
  exit "$_dump_rc"
fi
if [[ "$_psql_rc" != "0" ]]; then
  echo "错误: 远端 psql 导入失败（退出码 $_psql_rc）" >&2
  exit "$_psql_rc"
fi

echo "=== 完成：本地数据已导入 aws-alpha 库 ==="
