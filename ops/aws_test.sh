#!/usr/bin/env bash
# HZTech 运维菜单：AWS 双机网络 · SSH · HTTP · PostgreSQL 自检
# 数据库导入/迁移：aws-ops/database/pg_ops.sh / aws-ops/database/pg_ows_import.py
# 配置：baasapi/deploy-aws.json（aws-ops/lib/read_deploy_config.py、aws_ops.sh）
# UTF-8 终端下中文与图标显示最佳
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

_OPS_ALL_LOADED=0
_ensure_deploy_all() {
  if [[ "$_OPS_ALL_LOADED" -eq 1 ]]; then
    return 0
  fi
  # shellcheck disable=SC1090
  eval "$(python3 "$SCRIPT_DIR/lib/read_deploy_config.py" --bash-export-all)" || {
    echo "❌ 读取部署配置失败（read_deploy_config.py --bash-export-all）" >&2
    return 1
  }
  _OPS_ALL_LOADED=1
}

_hdr() { printf '\n%s\n' "$*"; }

_show_banner() {
  printf '\n'
  printf '╔══════════════════════════════════════════════════════════╗\n'
  printf '║  HZTech 运维菜单  ·  deploy-aws.json                   ║\n'
  printf '╚══════════════════════════════════════════════════════════╝\n'
}

_pause() {
  read -r -p "按 Enter 返回菜单…" _ </dev/tty 2>/dev/null || true
}

_menu_main() {
  _show_banner
  printf '\n━━ 🌐 网络 · SSH · 应用 ━━\n'
  printf '  1  📡 公网 HTTP：BaasAPI + Flutter 静态（双机）\n'
  printf '  2  📶 Ping：两台 EC2 主机\n'
  printf '  3  🔑 SSH 登录 BaasAPI 机（交互）\n'
  printf '  4  🔑 SSH 登录 Flutter 静态机（交互）\n'
  printf '  5  🖥️  BaasAPI HTTP 接口测试（Python）\n'
  printf '\n━━ 🗄️  PostgreSQL 自检 ━━\n'
  printf '  6  🏠 本机 PostgreSQL（aws-ops/database/pg_ops.sh test-local）\n'
  printf '  7  ☁️  AWS 只读检查（aws-ops/database/pg_ops.sh test-aws）\n'
  printf '\n  0  ❌ 退出\n'
  printf '\n请选择 [0-7]: '
}

_run_choice() {
  local c="${1:-}"
  shift || true
  if [[ "$c" =~ ^[0-9]+$ ]]; then
    c=$((10#$c))
  fi
  case "$c" in
  0 | "")
    printf '再见。\n'
    exit 0
    ;;
  1)
    _hdr "▶️  1 公网 HTTP（aws_ops.sh status all）"
    bash "$SCRIPT_DIR/aws_ops.sh" status all
    ;;
  2)
    _hdr "▶️  2 Ping 两台主机"
    _ensure_deploy_all || return 1
    printf '  📡 BaasAPI  %s\n' "$OPS_BAASAPI_SSH_HOST"
    ping -c 2 -q "$OPS_BAASAPI_SSH_HOST" || true
    printf '\n  📡 Flutter  %s\n' "$OPS_FLUTTER_SSH_HOST"
    ping -c 2 -q "$OPS_FLUTTER_SSH_HOST" || true
    ;;
  3)
    _hdr "▶️  3 SSH → BaasAPI 机"
    _ensure_deploy_all || return 1
    printf '登录 %s@%s …\n' "$OPS_BAASAPI_SSH_USER" "$OPS_BAASAPI_SSH_HOST"
    ssh -t -o LogLevel=ERROR -i "$OPS_BAASAPI_SSH_KEY" -p "$OPS_BAASAPI_SSH_PORT" \
      "${OPS_BAASAPI_SSH_OPTS[@]}" \
      "${OPS_BAASAPI_SSH_USER}@${OPS_BAASAPI_SSH_HOST}"
    ;;
  4)
    _hdr "▶️  4 SSH → Flutter 静态机"
    _ensure_deploy_all || return 1
    printf '登录 %s@%s …\n' "$OPS_FLUTTER_SSH_USER" "$OPS_FLUTTER_SSH_HOST"
    ssh -t -o LogLevel=ERROR -i "$OPS_FLUTTER_SSH_KEY" -p "$OPS_FLUTTER_SSH_PORT" \
      "${OPS_FLUTTER_SSH_OPTS[@]}" \
      "${OPS_FLUTTER_SSH_USER}@${OPS_FLUTTER_SSH_HOST}"
    ;;
  5)
    _hdr "▶️  5 BaasAPI HTTP 接口测试"
    _ensure_deploy_all || return 1
    export BASE_URL="${BASE_URL:-$OPS_BAASAPI_PUBLIC_URL}"
    python3 "$PROJECT_ROOT/test/test_aws_api.py" "$@"
    ;;
  6)
    _hdr "▶️  6 本机 PostgreSQL"
    bash "$SCRIPT_DIR/database/pg_ops.sh" test-local
    ;;
  7)
    _hdr "▶️  7 AWS PostgreSQL（只读）"
    bash "$SCRIPT_DIR/database/pg_ops.sh" test-aws "$@"
    ;;
  *)
    printf '❌ 无效选择: %s（有效范围 0–7）\n' "$c" >&2
    return 2
    ;;
  esac
}

# 非交互：./aws-ops/aws_test.sh 5 -v  |  ./aws-ops/aws_test.sh run 7
if [[ "${1:-}" == "run" ]]; then
  shift || true
  [[ -n "${1:-}" ]] || {
    printf '用法: %s run <0-7> [额外参数…]\n' "$0" >&2
    exit 2
  }
  c="$1"
  shift || true
  _run_choice "$c" "$@"
  exit $?
fi
if [[ -n "${1:-}" ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
  c="$1"
  shift || true
  _run_choice "$c" "$@"
  exit $?
fi

if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
  printf '请在本机交互终端运行：\n  ./aws-ops/aws_test.sh\n' >&2
  printf '或非交互：./aws-ops/aws_test.sh 1   /   ./aws-ops/aws_test.sh run 5 -v   /   ./aws-ops/aws_test.sh run 7\n' >&2
  exit 1
fi

while true; do
  _menu_main
  read -r raw </dev/tty || exit 1
  raw="${raw//[[:space:]]/}"
  if [[ -z "$raw" ]]; then
    printf '（空输入，已忽略）\n'
    continue
  fi
  choice="${raw//[^0-9]/}"
  if [[ -z "$choice" ]]; then
    printf '请输入 0–7 的数字。\n'
    continue
  fi
  choice=$((10#$choice))
  if [[ "$choice" -eq 0 ]]; then
    printf '再见。\n'
    exit 0
  fi
  if [[ "$choice" -gt 7 ]]; then
    printf '请输入 0–7（全库导入请用 ./aws-ops/database/pg_ops.sh 或 python3 aws-ops/database/pg_ows_import.py）。\n'
    continue
  fi
  set +e
  _run_choice "$choice"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && [[ "$rc" -ne 130 ]]; then
    printf '\n⚠️  上一步退出码: %s\n' "$rc"
  fi
  _pause
done
