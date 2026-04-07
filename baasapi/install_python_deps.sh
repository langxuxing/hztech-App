#!/usr/bin/env bash
# 安装 BaasAPI 运行时依赖（与 baasapi/requirements.txt 一致）。
# 用法（项目根）: ./baasapi/install_python_deps.sh
# 额外参数会原样传给 pip，例如: ./baasapi/install_python_deps.sh --user
# 跳过: export HZTECH_SKIP_PIP_INSTALL=1
set -euo pipefail

case "${HZTECH_SKIP_PIP_INSTALL:-}" in
1 | true | yes) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ="$SCRIPT_DIR/requirements.txt"

if ! command -v python3 >/dev/null 2>&1; then
  echo "错误: 需要 python3" >&2
  exit 1
fi

if [[ ! -f "$REQ" ]]; then
  echo "错误: 未找到 $REQ" >&2
  exit 1
fi

echo "=== pip install -r baasapi/requirements.txt ==="
python3 -m pip install -r "$REQ" "$@"
