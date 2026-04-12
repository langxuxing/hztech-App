#!/usr/bin/env bash
# Ops 本地一站式：逻辑在 aws-ops/code/deploy_orchestrator.py（子命令 local）。
# 本脚本为薄封装；编排器固定输出「阶段 1/8 … 阶段 8/8」（本地，deploy_ui.DEPLOY_STAGE_TOTAL_LOCAL）。
#
# 等价：python3 aws-ops/code/deploy_orchestrator.py local [选项...]
# 常用：./deploy2Local.sh　./deploy2Local.sh --db　./deploy2Local.sh --no-start --verify
#       ./deploy2Local.sh --skip-build　./deploy2Local.sh --skip-pip
# 无参数且在交互式终端：先打印说明与选项菜单，确认后再执行（见 aws-ops/code/deploy_interactive.sh）。
# 跳过菜单：传入任意参数，或 CI=1 / HZTECH_DEPLOY_YES=1 / HZTECH_DEPLOY_NONINTERACTIVE=1。
#
# 默认行为（无参数且非交互式终端 / 已跳过向导时，直接走编排器）：
#   · 数据库：HZTECH_DB_BACKEND=postgresql（连接见 baasapi/database_config.json）
#   · 不执行 init_db：仅 --db / -db / HZTECH_DB_SYNC=1 等触发本地迁移
#   · Flutter：release Android APK + release Web（iOS 默认跳过，除非 HZTECH_SKIP_IOS_BUILD=0）
#   · 收尾：pip 依赖 → 构建 → exec baasapi/run_local.sh（API + Web 静态）
#
# 环境变量仍生效（如 HZTECH_DB_BACKEND、HZTECH_DB_SYNC、HZTECH_SKIP_BUILD、
# HZTECH_SKIP_PIP_INSTALL、HZTECH_POST_DEPLOY_VERIFY、HZTECH_LOCAL_API_PORT、
# HZTECH_LOCAL_WEB_PORT、FLUTTER_DART_DEFINE_FILE 等），详见 orchestrator --help。
#
# 可选：远端 PostgreSQL 安装（SSH）— HZTECH_SSH_INSTALL_PG_AWS_ALPHA=1，目标见 HZTECH_SSH_PG_TARGET。
#
# SQLite → PostgreSQL（与本地启动无关，需单独执行）：
#   python3 baasapi/migrate_sqlite_to_postgresql.py --dry-run
#   python3 aws-ops/code/deploy_orchestrator.py migrate-sqlite-pg --dry-run
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# shellcheck source=aws-ops/code/deploy_common.sh
source "$PROJECT_ROOT/aws-ops/code/deploy_common.sh"

hztech_require_python3

RUN_LOCAL_SH="$PROJECT_ROOT/baasapi/run_local.sh"
ORCH_PY="$(hztech_orchestrator_py)"
if [[ ! -f "$RUN_LOCAL_SH" ]]; then
  echo "❌ 错误: 未找到本地启动脚本: $RUN_LOCAL_SH" >&2
  exit 1
fi
if [[ ! -f "$ORCH_PY" ]]; then
  echo "❌ 错误: 未找到编排脚本: $ORCH_PY" >&2
  exit 1
fi

ORCH_ARGS=( "$@" )
if hztech_need_deploy_interactive "$@"; then
  # shellcheck source=aws-ops/code/deploy_interactive.sh
  source "$PROJECT_ROOT/aws-ops/code/deploy_interactive.sh"
  hztech_run_local_wizard || exit 0
  ORCH_ARGS=( "${HZTECH_WIZARD_ARGS[@]}" )
fi

_ssh_pg=$(printf '%s' "${HZTECH_SSH_INSTALL_PG_AWS_ALPHA:-}" | tr '[:upper:]' '[:lower:]')
if [[ "$_ssh_pg" == "1" || "$_ssh_pg" == "true" || "$_ssh_pg" == "yes" ]]; then
  echo ""
  echo "🗄️  可选步骤：远端 PostgreSQL 安装（HZTECH_SSH_INSTALL_PG_AWS_ALPHA=1）"
  echo "   🔗 SSH 目标: ${HZTECH_SSH_PG_TARGET:-aws-alpha}"
  echo "──────────────────────────────────────────────────────────"
  bash "$PROJECT_ROOT/aws-ops/database/install_postgresql_remote.sh" "${HZTECH_SSH_PG_TARGET:-aws-alpha}"
  echo "✅ 远端 PostgreSQL 安装脚本已执行完毕"
  echo "──────────────────────────────────────────────────────────"
fi
unset _ssh_pg

# 与线上一致：默认产物名 hztech-app-release.apk（本地无 rsync，仅与 API 下载名对齐）
export HZTECH_APP_ANDROID_APK="${HZTECH_APP_ANDROID_APK:-hztech-app-release.apk}"

echo ""
echo "🚀 deploy2Local.sh → 进入 Python 编排（本地流水线，详细步骤见下方输出）"
echo "──────────────────────────────────────────────────────────"

export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
_PY="$(command -v python3)"
exec "$_PY" "$ORCH_PY" local "${ORCH_ARGS[@]}"
