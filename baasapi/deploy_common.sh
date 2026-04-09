#!/usr/bin/env bash
# 供项目根目录 deploy2AWS.sh / deploy2Local.sh source。
# 前置条件：已设置 PROJECT_ROOT 且当前工作目录为项目根。
#
# 提供：hztech_require_python3 —— 检查 command python3 可用

hztech_require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "错误: 需要 python3" >&2
    return 1
  fi
  if ! command python3 -c "import sys" 2>/dev/null; then
    echo "错误: 无法执行 Python（请检查 PATH 与 python3 安装）" >&2
    return 1
  fi
  return 0
}

hztech_orchestrator_py() {
  printf '%s' "${PROJECT_ROOT}/baasapi/deploy_orchestrator.py"
}
