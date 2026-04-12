#!/usr/bin/env bash
# 经 SSH 在 deploy-aws.json 所配置的 BaasAPI 主机上执行 OKX bills-archive 缺日补全
#（写入 account_balance_snapshots，逻辑同 baasapi/pg_data_fill.py）。
#
# 依赖远端：已部署仓库、Python 环境、DATABASE_URL（或 HZTECH_DB_BACKEND 等）与 accounts 下 OKX 密钥。
#
# 用法（在仓库根目录）：
#   chmod +x aws-ops/code/balance_snapshots_bills_backfill.sh
#   ./aws-ops/code/balance_snapshots_bills_backfill.sh
#   ./aws-ops/code/balance_snapshots_bills_backfill.sh --days 60 --account HzTech_MainRepo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
eval "$("$SCRIPT_DIR/../lib/read_deploy_config.py" --bash-export-all)"

ssh -o LogLevel=ERROR -i "$OPS_BAASAPI_SSH_KEY" -p "$OPS_BAASAPI_SSH_PORT" \
  "${OPS_BAASAPI_SSH_OPTS[@]}" \
  "${OPS_BAASAPI_SSH_USER}@${OPS_BAASAPI_SSH_HOST}" \
  bash -s -- "$OPS_BAASAPI_REMOTE_PATH" "$@" <<'REMOTE'
set -euo pipefail
cd "${1}/baasapi"
shift
exec python3 pg_data_fill.py "$@"
REMOTE
