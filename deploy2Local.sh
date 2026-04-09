#!/usr/bin/env bash
# 本地一站式：逻辑在 baasapi/deploy_orchestrator.py（子命令 local）。
#
# 默认行为（无额外参数时）：
#   · 数据库后端：PostgreSQL（HZTECH_DB_BACKEND=postgresql，连接见 baasapi/database_config.json）
#   · 不执行 init_db：仅当传 --db / -db / HZTECH_DB_SYNC=1 等时才跑本地迁移
#   · Flutter：默认 release Android APK（hztech-app-release.apk）+ release Web（iOS 默认跳过）
#   · 启动：pip 依赖后构建，再 exec baasapi/run_local.sh（API+Web 静态，端口见脚本输出）
#
# 可选远端 PostgreSQL 安装：HZTECH_SSH_INSTALL_PG_AWS_ALPHA=1（与本脚本前几行一致）。
#
# 表结构手工 SQL / 对照：baasapi/migrations/（如 add_account_tables.sql、add_account_tables.postgresql.sql、add_account_daily_performance.postgresql.sql）；
# 正常运行由 main.py 启动时 init_db() / pg_run_init() 建表与迁移。
#
# SQLite → PostgreSQL（与本地启动无关，需单独执行）：
#   python3 baasapi/migrate_sqlite_to_postgresql.py --dry-run
#   python3 baasapi/deploy_orchestrator.py migrate-sqlite-pg --dry-run
# 详见 baasapi/migrate_sqlite_to_postgresql.py 文件头；PG 连接用 DATABASE_URL 或 database_config.json。
#
# 等价：python3 baasapi/deploy_orchestrator.py local [选项...]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# shellcheck source=baasapi/deploy_common.sh
source "$PROJECT_ROOT/baasapi/deploy_common.sh"

_ssh_pg=$(printf '%s' "${HZTECH_SSH_INSTALL_PG_AWS_ALPHA:-}" | tr '[:upper:]' '[:lower:]')
if [[ "$_ssh_pg" == "1" || "$_ssh_pg" == "true" || "$_ssh_pg" == "yes" ]]; then
  printf '\n'
  echo "=== （可选）远端 PostgreSQL（HZTECH_SSH_INSTALL_PG_AWS_ALPHA，SSH: ${HZTECH_SSH_PG_TARGET:-aws-alpha}）==="
  bash "$PROJECT_ROOT/baasapi/install_postgresql_remote.sh" "${HZTECH_SSH_PG_TARGET:-aws-alpha}"
fi
unset _ssh_pg

hztech_require_python3

# 与线上一致：默认构建/引用 hztech-app-release.apk（本地无远端 rsync，仅产物与 API 下载名对齐）
export HZTECH_APP_ANDROID_APK="${HZTECH_APP_ANDROID_APK:-hztech-app-release.apk}"

_PY="$(command -v python3)"
exec "$_PY" "$(hztech_orchestrator_py)" local "$@"
