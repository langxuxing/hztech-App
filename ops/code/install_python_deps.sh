#!/usr/bin/env bash
# 安装 BaasAPI 运行时依赖（与 baasapi/requirements.txt 一致）。
# 用法（项目根）: ./aws-ops/code/install_python_deps.sh
# 默认在 baasapi/.venv 中安装（兼容 Homebrew 等 PEP 668 externally-managed-environment）。
# 覆盖虚拟环境目录: export HZTECH_PYTHON_VENV=/path/to/venv
# 强制用当前 python3 直装系统 site-packages（不推荐）: HZTECH_USE_SYSTEM_PIP=1
# 额外参数会原样传给 pip。
# 跳过: export HZTECH_SKIP_PIP_INSTALL=1
set -euo pipefail

case "${HZTECH_SKIP_PIP_INSTALL:-}" in
1 | true | yes) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REQ="$PROJECT_ROOT/baasapi/requirements.txt"
VENV="${HZTECH_PYTHON_VENV:-$PROJECT_ROOT/baasapi/.venv}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "错误: 需要 python3" >&2
  exit 1
fi

if [[ ! -f "$REQ" ]]; then
  echo "错误: 未找到 $REQ" >&2
  exit 1
fi

case "${HZTECH_USE_SYSTEM_PIP:-}" in
1 | true | yes)
  echo "=== pip install -r baasapi/requirements.txt (system python, HZTECH_USE_SYSTEM_PIP) ==="
  python3 -m pip install -r "$REQ" "$@"
  exit $?
  ;;
esac

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "=== 创建虚拟环境: $VENV ==="
  python3 -m venv "$VENV"
fi

echo "=== pip install -r baasapi/requirements.txt (venv: $VENV) ==="
"$VENV/bin/python" -m pip install -r "$REQ" "$@"
