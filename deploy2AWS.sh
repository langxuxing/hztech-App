#!/usr/bin/env bash
# Ops 一键部署：逻辑在 baasapi/deploy_orchestrator.py（子命令 aws）。
# 本脚本为薄封装；目标机与路径由 DEPLOY_CONFIG（默认 baasapi/deploy-aws.json）决定。
# 双机（默认 baasapi/deploy-aws.json）：BaasAPI → aws-alpha 54.66.108.150:9001（hztech.pem）；
# Flutter 静态站 → aws-defi 54.252.181.151:9000（aws-defi.pem）。各段 host/key/port 以 JSON 为准。
# remote_path 一般为 /home/ec2-user/hztechapp，其下为 baasapi/、flutterapp/build/web、apk/ 等。
#
# 等价：python3 baasapi/deploy_orchestrator.py aws [选项...]
# 常用：./deploy2AWS.sh   ./deploy2AWS.sh --db   ./deploy2AWS.sh --verify
# 默认仅 rsync 上传 apk/hztech-app-release.apk；全量同步可：HZTECH_DEPLOY_APK_ONLY=0 ./deploy2AWS.sh
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

# 仅上传 apk/hztech-app-release.apk（不全量 rsync）；见 baasapi/server_mgr.py rsync_sync
export HZTECH_DEPLOY_APK_ONLY="${HZTECH_DEPLOY_APK_ONLY:-1}"

_PY="$(command -v python3)"
exec "$_PY" "$(hztech_orchestrator_py)" aws "$@"
