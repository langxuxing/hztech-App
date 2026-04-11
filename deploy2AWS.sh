#!/usr/bin/env bash
# Ops 一键部署：逻辑在 baasapi/deploy_orchestrator.py（子命令 aws）。
# 本脚本为薄封装；编排器始终输出「阶段 1/9 … 阶段 9/9」（AWS）。HZTECH_DEPLOY_QUIET=1 仅减少 rsync/SSH/pip 刷屏（见 server_mgr）。
# 阶段 5 rsync：静默时仍打印每段「目标+耗时+--stats」；无逐文件列表。逐文件请 HZTECH_DEPLOY_QUIET=0。
# 分段耗时: HZTECH_DEPLOY_DEBUG_TIMING=1 ./deploy2AWS.sh（[deploy-timing]）。
# 双机（默认 baasapi/deploy-aws.json）：BaasAPI → aws-alpha 54.66.108.150:9001（hztech.pem）；
# Flutter 静态站 → aws-defi 54.252.181.151:9000（aws-defi.pem）。各段 host/key/port 以 JSON 为准。
# remote_path 一般为 /home/ec2-user/hztechapp；aws-defi（Flutter 段）下仅 apk/、flutterapp/（含 build/web、web_static），无 baasapi/。
# （hztechapp 为 EC2 目录名；PostgreSQL 生产库名一般为 hztech，schema flutterapp，见 baasapi/README-DEPLOY.md）
#
# 运维脚本在项目根下 ops/：例如 ops/gp_ops.sh、ops/pg_ows_import.py、ops/hztech_ops_menu.sh、
# ops/read_deploy_config.py；与部署配置、SSH 约定一致。
#
# 等价：python3 baasapi/deploy_orchestrator.py aws [选项...]
# 常用：./deploy2AWS.sh   ./deploy2AWS.sh --db   ./deploy2AWS.sh --verify
# 无参数且在交互式终端：先打印说明与选项菜单，确认后再执行（见 baasapi/deploy_interactive.sh）。
# 跳过菜单：传入任意参数，或 CI=1 / HZTECH_DEPLOY_YES=1 / HZTECH_DEPLOY_NONINTERACTIVE=1。
#
# 默认（本脚本导出；交互向导会在确认前覆盖部分 HZTECH_*）：全量 rsync BaasAPI@aws-alpha + Flutter 静态机；不构建 Android/APK、不向远端同步 apk/；
# rsync 排除项目根下 res/、ops/ 等（见 baasapi/server_mgr.py _rsync_deploy_exclude_patterns）。
# 若仅需上传 release APK：HZTECH_DEPLOY_APK_ONLY=1 ./deploy2AWS.sh（双机时推到 BaasAPI + Flutter 静态机各一份）
# 若要在本次流水线中构建并同步 APK：HZTECH_SKIP_MOBILE_BUILD=0 HZTECH_DEPLOY_SKIP_APK_SYNC=0 ./deploy2AWS.sh --build android,web
#
# 环境变量仍生效（如 DEPLOY_CONFIG、HZTECH_API_BASE_URL、HZTECH_SKIP_BUILD、HZTECH_DB_SYNC、
# HZTECH_POST_DEPLOY_VERIFY、HZTECH_DEPLOY_QUIET、HZTECH_SKIP_REMOTE_PIP、
# HZTECH_PIP_REMOTE_TIMEOUT_SEC（阶段 7 pip 超时秒数，默认 3600；0=不限）等），详见 orchestrator --help。
# 远端 pip 为阶段 7（pip-remote，默认完整 pip 日志）；阶段 8 仅 restart。依赖已齐可 HZTECH_SKIP_REMOTE_PIP=1 跳过阶段 7。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# shellcheck source=baasapi/deploy_common.sh
source "$PROJECT_ROOT/baasapi/deploy_common.sh"

DEPLOY_CONFIG="${DEPLOY_CONFIG:-baasapi/deploy-aws.json}"
if [[ ! -f "$DEPLOY_CONFIG" ]]; then
  echo "❌ 错误: 未找到部署配置: $DEPLOY_CONFIG" >&2
  exit 1
fi
hztech_require_python3

# 见上方说明；与 baasapi/server_mgr.py rsync_sync 一致
export HZTECH_DEPLOY_APK_ONLY="${HZTECH_DEPLOY_APK_ONLY:-0}"
export HZTECH_DEPLOY_SKIP_APK_SYNC="${HZTECH_DEPLOY_SKIP_APK_SYNC:-1}"
export HZTECH_SKIP_MOBILE_BUILD="${HZTECH_SKIP_MOBILE_BUILD:-1}"
# 默认静默：rsync/SSH/pip 少刷屏，失败时仍打印捕获输出；阶段标题仍会打印。需 rsync/pip 全程详细输出: HZTECH_DEPLOY_QUIET=0 ./deploy2AWS.sh
export HZTECH_DEPLOY_QUIET="${HZTECH_DEPLOY_QUIET:-1}"
# 默认部署结束后 HTTP 探测 API/Web，通过则一行结束
export HZTECH_POST_DEPLOY_VERIFY="${HZTECH_POST_DEPLOY_VERIFY:-1}"
# 远端 BaasAPI 注入 HZTECH_TRADINGBOT_CTRL_DIR（策略 shell）；勿用本机 Mac 路径。覆盖：HZTECH_REMOTE_TRADINGBOT_CTRL_DIR=...
export HZTECH_REMOTE_TRADINGBOT_CTRL_DIR="${HZTECH_REMOTE_TRADINGBOT_CTRL_DIR:-/home/ec2-user/Alpha}"

ORCH_ARGS=( "$@" )
if hztech_need_deploy_interactive "$@"; then
  # shellcheck source=baasapi/deploy_interactive.sh
  source "$PROJECT_ROOT/baasapi/deploy_interactive.sh"
  hztech_run_aws_wizard || exit 0
  ORCH_ARGS=( "${HZTECH_WIZARD_ARGS[@]}" )
fi

if [[ "${HZTECH_DEPLOY_QUIET}" != "1" && "${HZTECH_DEPLOY_QUIET}" != "true" && "${HZTECH_DEPLOY_QUIET}" != "yes" ]]; then
  echo ""
  echo "🚀 deploy2AWS.sh → 进入 Python 编排（详细步骤见下方输出）"
  echo "──────────────────────────────────────────────────────────"
fi

export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
_PY="$(command -v python3)"
exec "$_PY" "$(hztech_orchestrator_py)" aws "${ORCH_ARGS[@]}"
