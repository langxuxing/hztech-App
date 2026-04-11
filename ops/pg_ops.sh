#!/usr/bin/env bash
# PostgreSQL 运维统一入口：本机/AWS 自检、本地→AWS 导入、旧版 bash 管道 dump。
# 实现：委派 ops/pg_ows_import.py、ops/test_local_postgres.py、ops/test_aws_postgres.py、
#       ops/pg_dump_to_aws_alpha.sh（纯 bash pg_dump|psql，与 Python 导入二选一即可）。
#
# 用法：
#   ./ops/pg_ops.sh                    # 无参数：等同 pg_ows_import.py（默认仅应用 schema，与 database_config 一致）
#   ./ops/pg_ops.sh --dry-run          # 以「-」开头：参数全部交给 pg_ows_import.py
#   ./ops/pg_ops.sh import --dry-run
#   ./ops/pg_ops.sh test-local
#   ./ops/pg_ops.sh test-aws [--role baasapi]
#   ./ops/pg_ops.sh dump-alpha [--dry-run|--backup-remote-first]
#   ./ops/pg_ops.sh help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

_usage() {
  cat <<'EOF'
PostgreSQL 运维（ops/pg_ops.sh）

  ./ops/pg_ops.sh                     无参：本地→AWS 导入（默认 pg_dump 仅应用 schema，见 database_config）
  ./ops/pg_ops.sh --dry-run           以 - 开头：参数全部交给导入脚本
  ./ops/pg_ops.sh import [参数…]      同上
  ./ops/pg_ops.sh test-local          本机 PostgreSQL 自检
  ./ops/pg_ops.sh test-aws [参数…]    AWS 经 SSH 只读检查
  ./ops/pg_ops.sh dump-alpha [参数…]  旧版 bash：pg_dump|psql（同 pg_dump_to_aws_alpha.sh）
EOF
}

_first="${1:-}"
if [[ -z "$_first" ]]; then
  exec python3 "$SCRIPT_DIR/pg_ows_import.py"
fi

if [[ "$_first" =~ ^- ]]; then
  exec python3 "$SCRIPT_DIR/pg_ows_import.py" "$@"
fi

case "$_first" in
import)
  shift
  exec python3 "$SCRIPT_DIR/pg_ows_import.py" "$@"
  ;;
test-local)
  shift
  exec python3 "$SCRIPT_DIR/test_local_postgres.py" "$@"
  ;;
test-aws)
  shift
  exec python3 "$SCRIPT_DIR/test_aws_postgres.py" "$@"
  ;;
dump-alpha)
  shift
  exec bash "$SCRIPT_DIR/pg_dump_to_aws_alpha.sh" "$@"
  ;;
help | -h | --help)
  _usage
  ;;
*)
  printf '未知子命令: %s\n\n' "$_first" >&2
  _usage >&2
  exit 2
  ;;
esac
