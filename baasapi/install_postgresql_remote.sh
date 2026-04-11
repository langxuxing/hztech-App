#!/usr/bin/env bash
# 通过 SSH 在远端主机安装并初始化 PostgreSQL（默认目标：~/.ssh/config 中的 Host aws-alpha）。
# 运维约定：aws-alpha 即 BaasAPI 所在 EC2，公网 IP 与 baasapi/deploy-aws.json 中 baasapi.host 一致（当前 54.66.108.150）。
# 约定：PostgreSQL 数据库名 hztech，schema flutterapp，用户 hztech（与 database_config.example.json 一致）。
#   EC2 项目目录名常为 hztechapp（remote_path），与数据库名无关。
# 将本机 PostgreSQL 备份导入此机：../ops/gp_ops.sh 或 ../ops/pg_ows_import.py（远端仅监听 127.0.0.1，经 SSH 管道导入）。
# 导入后验证：../ops/gp_ops.sh test-aws，或 ./ops/hztech_ops_menu.sh 选 7。
# 支持 Amazon Linux 2023 / Amazon Linux 2（yum/dnf）与 Debian/Ubuntu（apt）。
#
# 用法：
#   bash baasapi/install_postgresql_remote.sh [ssh_target]
#   HZTECH_PG_USER=hztech HZTECH_PG_PASSWORD='...' HZTECH_PG_DB=hztech bash baasapi/install_postgresql_remote.sh aws-alpha
#
# 可选：
#   HZTECH_SSH_OPTS   追加传给 ssh 的选项（整段原样展开，例如: export HZTECH_SSH_OPTS='-i /path/key.pem'）
#   HZTECH_SSH_PG_TARGET  覆盖 SSH 目标（优先于第 1 参数）。默认即 ec2-user@54.66.108.150
#   HZTECH_SKIP_SSH_RESOLVE_CHECK=1  跳过「解析到 198.18.x.x」时的报错（一般不需要）
#   HZTECH_SSH_KEY_FILE  显式指定私钥；未设置且 HZTECH_SSH_OPTS 为空时，会自动读取 baasapi/deploy-aws.json 的 baasapi.key
#
# 排障：若出现「Connection closed by 198.18.0.x」，说明本机把 Host 解析到了 RFC2544 测试段（常见于 VPN/分流）。
#   · 方式 2：将 baasapi/ssh_snippet_aws_alpha 中 Host 段合并到 ~/.ssh/config
#   · 或: export HZTECH_SSH_PG_TARGET=ec2-user@54.66.108.150
#
# 密码经 base64 传入远端，避免 shell 引号问题；未设置 HZTECH_PG_PASSWORD 时默认 Alpha（与 database_config.example.json 一致）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

SSH_TARGET="${HZTECH_SSH_PG_TARGET:-${1:-ec2-user@54.66.108.150}}"
# 常见误输入 aws-alpha~（编辑器备份后缀）；全角括号紧跟 $var 在 UTF-8 下可能被 bash 误解析，故用 ${}
SSH_TARGET="${SSH_TARGET%\~}"
PG_USER="${HZTECH_PG_USER:-hztech}"
PG_DB="${HZTECH_PG_DB:-hztech}"
PG_SCHEMA="${HZTECH_PG_SCHEMA:-flutterapp}"
PG_PASS="${HZTECH_PG_PASSWORD:-Alpha}"
PG_PASS_B64="$(printf '%s' "$PG_PASS" | base64 | tr -d '\n')"

echo "=== 远端安装 PostgreSQL: $SSH_TARGET ==="
echo "  库用户: ${PG_USER}  数据库: ${PG_DB}  schema: ${PG_SCHEMA}（密码已隐藏）"

if [[ "${HZTECH_SKIP_SSH_RESOLVE_CHECK:-0}" != "1" ]]; then
  _rh="$SSH_TARGET"
  [[ "$_rh" == *@* ]] && _rh="${_rh#*@}"
  if [[ "$_rh" =~ ^[0-9.]+$ ]]; then
    _rip="$_rh"
  else
    _rip="$(
      HZTECH_RESOLVE_HOST="$_rh" python3 -c 'import os, socket; print(socket.gethostbyname(os.environ["HZTECH_RESOLVE_HOST"]))' 2>/dev/null || true
    )"
  fi
  if [[ -n "${_rip}" ]]; then
    _o1="${_rip%%.*}"
    _rest="${_rip#*.}"
    _o2="${_rest%%.*}"
    if [[ "${_o1}" == "198" && ( "${_o2}" == "18" || "${_o2}" == "19" ) ]]; then
      echo "" >&2
      echo "错误: host ${_rh} 解析到 ${_rip} (198.18/19 多为 VPN 占位)，SSH 常会立刻断开。" >&2
      echo "请任选其一：" >&2
      echo "  1) export HZTECH_SSH_PG_TARGET=ec2-user@54.66.108.150 && bash \"$0\"" >&2
      echo "  2) 在 ~/.ssh/config 的 Host aws-alpha 下设置: HostName 54.66.108.150" >&2
      echo "(若确需跳过此检查: HZTECH_SKIP_SSH_RESOLVE_CHECK=1)" >&2
      exit 2
    fi
  fi
  unset _rh _rip _o1 _o2 _rest
fi

# 未提供 SSH 选项时，尝试自动使用 deploy-aws.json 中的 BaasAPI 私钥，减少手工 -i 出错。
_SSH_OPTS="${HZTECH_SSH_OPTS:-}"
if [[ -z "${_SSH_OPTS}" ]]; then
  _AUTO_KEY="${HZTECH_SSH_KEY_FILE:-}"
  if [[ -z "${_AUTO_KEY}" && -f "$PROJECT_ROOT/baasapi/deploy-aws.json" ]]; then
    _AUTO_KEY="$(
      python3 - <<'PY' 2>/dev/null || true
import json
from pathlib import Path
p = Path("baasapi/deploy-aws.json")
try:
    c = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
ba = c.get("baasapi") if isinstance(c.get("baasapi"), dict) else {}
key = ba.get("key") or c.get("key") or ""
print(str(key).strip())
PY
    )"
  fi
  if [[ -n "${_AUTO_KEY}" ]]; then
    _SSH_OPTS="-i ${_AUTO_KEY} -o StrictHostKeyChecking=accept-new"
    echo "  SSH 选项: 自动使用密钥 ${_AUTO_KEY}"
  fi
fi

# shellcheck disable=SC2086
ssh ${_SSH_OPTS:-} "$SSH_TARGET" env \
  HZTECH_PG_USER="$PG_USER" \
  HZTECH_PG_DB="$PG_DB" \
  HZTECH_PG_SCHEMA="$PG_SCHEMA" \
  HZTECH_PG_PASS_B64="$PG_PASS_B64" \
  bash -s <<'REMOTE'
set -euo pipefail
PG_USER="${HZTECH_PG_USER:?}"
PG_DB="${HZTECH_PG_DB:?}"
PG_SCHEMA="${HZTECH_PG_SCHEMA:-flutterapp}"
PG_PASS="$(echo "$HZTECH_PG_PASS_B64" | base64 -d)"
export PG_PASS

need_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@" 2>/dev/null || sudo "$@"
  fi
}

if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
else
  echo "错误: 无法识别系统（无 /etc/os-release）" >&2
  exit 1
fi

ID_LIKE="${ID_LIKE:-}"
SVC_NAME="postgresql"

pkg_has_version() {
  "$1" --version >/dev/null 2>&1
}

# 兼容 AL2023 上 /usr/bin/python3 被切到 pyenv 导致 dnf/yum 模块丢失
run_pkg_install() {
  _mgr="$1"; shift
  if [[ "$_mgr" == "dnf" || "$_mgr" == "yum" ]]; then
    if pkg_has_version "$_mgr"; then
      need_sudo "$_mgr" install -y "$@"
      return
    fi
    if [[ -x /usr/bin/python3.9 && -x "/usr/bin/${_mgr}" ]]; then
      echo "警告: ${_mgr} 当前 Python 环境异常，改用 /usr/bin/python3.9 /usr/bin/${_mgr}" >&2
      need_sudo /usr/bin/python3.9 "/usr/bin/${_mgr}" install -y "$@"
      return
    fi
    return 1
  fi
  need_sudo "$_mgr" install -y "$@"
}

install_al2023() {
  if command -v dnf >/dev/null 2>&1; then
    run_pkg_install dnf postgresql15-server postgresql15-contrib 2>/dev/null \
      || run_pkg_install dnf postgresql-server postgresql-contrib
  elif command -v yum >/dev/null 2>&1; then
    echo "警告: dnf 不可用，回退到 yum。" >&2
    run_pkg_install yum postgresql15-server postgresql15-contrib 2>/dev/null \
      || run_pkg_install yum postgresql-server postgresql-contrib
  elif command -v microdnf >/dev/null 2>&1 && pkg_has_version microdnf; then
    echo "警告: dnf/yum 不可用，回退到 microdnf。" >&2
    run_pkg_install microdnf postgresql15-server postgresql15-contrib 2>/dev/null \
      || run_pkg_install microdnf postgresql-server postgresql-contrib
  else
    echo "错误: 远端无可用包管理器（dnf/yum/microdnf）。请先修复系统包管理。" >&2
    exit 1
  fi
  if need_sudo test -f /usr/bin/postgresql-setup; then
    need_sudo /usr/bin/postgresql-setup --initdb 2>/dev/null || true
  fi
}

install_al2() {
  if command -v amazon-linux-extras >/dev/null 2>&1; then
    if need_sudo amazon-linux-extras list 2>/dev/null | grep -q postgresql; then
      need_sudo amazon-linux-extras enable postgresql14 2>/dev/null || need_sudo amazon-linux-extras enable postgresql13 2>/dev/null || true
    fi
  fi
  if command -v yum >/dev/null 2>&1; then
    run_pkg_install yum postgresql-server postgresql-contrib
  elif command -v dnf >/dev/null 2>&1; then
    run_pkg_install dnf postgresql-server postgresql-contrib
  else
    echo "错误: AL2 环境无可用 yum/dnf。" >&2
    exit 1
  fi
  if need_sudo test -x /usr/bin/postgresql-setup; then
    need_sudo postgresql-setup initdb 2>/dev/null || true
  fi
}

install_debian() {
  export DEBIAN_FRONTEND=noninteractive
  need_sudo apt-get update -y
  need_sudo apt-get install -y postgresql postgresql-contrib
}

case "${ID:-}" in
amzn)
  if [[ "${VERSION_ID:-}" == "2023"* ]] || [[ "${VERSION_ID:-}" == "2023" ]]; then
    echo "检测到 Amazon Linux 2023，安装 PostgreSQL …"
    install_al2023
  else
    echo "检测到 Amazon Linux 2，安装 PostgreSQL …"
    install_al2
  fi
  ;;
debian|ubuntu)
  echo "检测到 Debian/Ubuntu，安装 PostgreSQL …"
  install_debian
  SVC_NAME="postgresql"
  ;;
*)
  if echo "$ID_LIKE" | grep -q rhel; then
    echo "检测到 RHEL 系，尝试 dnf/yum 安装 …"
    install_al2023 || install_al2
  elif echo "$ID_LIKE" | grep -q debian; then
    install_debian
  else
    echo "错误: 未支持的发行版 ID=$ID" >&2
    exit 1
  fi
  ;;
esac

if need_sudo systemctl is-enabled "$SVC_NAME" &>/dev/null; then
  :
else
  need_sudo systemctl enable "$SVC_NAME" 2>/dev/null || true
fi
need_sudo systemctl start "$SVC_NAME"
need_sudo systemctl --no-pager --full status "$SVC_NAME" | head -20 || true

# 等待本地 socket
for _ in $(seq 1 30); do
  if need_sudo -u postgres psql -tAc "select 1" &>/dev/null; then
    break
  fi
  sleep 1
done

# SQL 单引号转义（密码中可含 '）
pwd_sql_lit() {
  python3 -c "import os; print(os.environ['PG_PASS'].replace(chr(39), chr(39)*2))"
}
PWD_SQL=$(pwd_sql_lit)

# 创建角色与库（幂等）
if need_sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$PG_USER'" | grep -q 1; then
  need_sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$PG_USER\" WITH LOGIN PASSWORD '$PWD_SQL';"
else
  need_sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$PG_USER\" WITH LOGIN PASSWORD '$PWD_SQL';"
fi

if ! need_sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$PG_DB'" | grep -q 1; then
  need_sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$PG_DB\" OWNER \"$PG_USER\";"
fi
# 库已存在但属主仍是 postgres 时，否则 PG15+ 在 public 上无 CREATE，BaasAPI 建表会失败
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$PG_DB\" OWNER TO \"$PG_USER\";"

# schema（幂等）+ 权限 + 缺省 search_path
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "CREATE SCHEMA IF NOT EXISTS \"$PG_SCHEMA\" AUTHORIZATION \"$PG_USER\";"
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "ALTER SCHEMA \"$PG_SCHEMA\" OWNER TO \"$PG_USER\";"
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "GRANT USAGE, CREATE ON SCHEMA \"$PG_SCHEMA\" TO \"$PG_USER\";"
# PostgreSQL 15+ 默认撤销 PUBLIC 在 schema public 上的 CREATE；若 search_path 回落到 public 需显式授权
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "GRANT USAGE, CREATE ON SCHEMA public TO \"$PG_USER\";"
need_sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" -c "ALTER ROLE \"$PG_USER\" IN DATABASE \"$PG_DB\" SET search_path TO \"$PG_SCHEMA\", public;"

echo "=== PostgreSQL 就绪 ==="
need_sudo -u postgres psql -c "\\l" | head -30 || true
echo "连接串示例: postgresql://${PG_USER}:***@127.0.0.1:5432/${PG_DB}  (search_path=${PG_SCHEMA},public)"
REMOTE

echo "=== 完成: 已在 $SSH_TARGET 上配置 PostgreSQL ==="
