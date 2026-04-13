#!/usr/bin/env bash
# 位于 ops/code/；供项目根目录 deploy2AWS.sh / deploy2Local.sh source。
# 前置条件：已设置 PROJECT_ROOT 且当前工作目录为项目根。
#
# 提供：hztech_require_python3 —— 检查 command python3 可用

hztech_require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ 错误: 需要 python3" >&2
    return 1
  fi
  if ! command python3 -c "import sys" 2>/dev/null; then
    echo "❌ 错误: 无法执行 Python（请检查 PATH 与 python3 安装）" >&2
    return 1
  fi
  return 0
}

hztech_orchestrator_py() {
  printf '%s' "${PROJECT_ROOT}/ops/code/deploy_orchestrator.py"
}

# 无参数、交互式终端、且未显式关闭向导时，deploy2Local.sh / deploy2AWS.sh 会先走菜单确认。
# 跳过方式：传入任意编排器参数；或 CI=1；或 HZTECH_DEPLOY_YES=1；或 HZTECH_DEPLOY_NONINTERACTIVE=1。
hztech_need_deploy_interactive() {
  if [[ $# -gt 0 ]]; then
    return 1
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    return 1
  fi
  case "${HZTECH_DEPLOY_NONINTERACTIVE:-}" in
    1 | true | TRUE | yes | YES) return 1 ;;
  esac
  case "${HZTECH_DEPLOY_YES:-}" in
    1 | true | TRUE | yes | YES) return 1 ;;
  esac
  if [[ -n "${CI:-}" ]]; then
    return 1
  fi
  return 0
}
