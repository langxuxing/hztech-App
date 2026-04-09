#!/usr/bin/env bash
# 对 aws-alpha（baasapi/deploy-aws.json 中 baasapi 段）上的 BaasAPI 跑 HTTP 探测。
# 与 ops/aws_ops.sh status api 使用同一套 URL（OPS_BAASAPI_PUBLIC_URL）。
#
#   ./ops/test_aws_alpha_baasapi.sh
#   ./ops/test_aws_alpha_baasapi.sh -v
#   ./ops/test_aws_alpha_baasapi.sh --user admin --password '***'
#
# 覆盖地址（不读 deploy-aws.json）：
#   BASE_URL=http://127.0.0.1:9001 ./ops/test_aws_alpha_baasapi.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1090
eval "$("$SCRIPT_DIR/read_deploy_config.py" --bash-export-all)"
export BASE_URL="${BASE_URL:-$OPS_BAASAPI_PUBLIC_URL}"
exec python3 "$PROJECT_ROOT/test/test_aws_api.py" "$@"
