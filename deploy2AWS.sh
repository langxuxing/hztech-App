#!/usr/bin/env bash
# Ops 一键部署：逻辑在 baasapi/deploy_orchestrator.py（子命令 aws）。
# 本脚本为薄封装，保持原路径与 DEPLOY_CONFIG 约定。
#
# 等价：python3 baasapi/deploy_orchestrator.py aws [选项...]
# 常用：./deploy2AWS.sh   ./deploy2AWS.sh --db   ./deploy2AWS.sh --verify
#
# 环境变量仍生效（如 DEPLOY_CONFIG、HZTECH_API_BASE_URL、HZTECH_SKIP_BUILD、
# HZTECH_DB_SYNC、HZTECH_POST_DEPLOY_VERIFY 等），详见 orchestrator --help。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# shellcheck source=baasapi/deploy_common.sh
source "$PROJECT_ROOT/baasapi/deploy_common.sh"

DEPLOY_CONFIG="${DEPLOY_CONFIG:-baasapi/deploy-aws.json}"
if [[ ! -f "$DEPLOY_CONFIG" ]]; then
  echo "错误: 未找到部署配置: $DEPLOY_CONFIG" >&2
  exit 1
fi
hztech_require_python3

_PY="$(command -v python3)"
exec "$_PY" "$(hztech_orchestrator_py)" aws "$@"
