#!/usr/bin/env bash
# Ops 一键部署：构建 Flutter → rsync →（可选）远程 DB 迁移 → 重启远端进程
#
# 目录约定：运维脚本在项目根；Python/配置在 baasapi/（server_mgr、deploy-aws.json、main.py 等）。
# 默认线上（见 baasapi/deploy-aws.json）：
#   · App/Web 静态：54.252.181.151:9000（flutterapp 段）
#   · BaasAPI：54.66.108.150:9001（baasapi 段）
# 构建时 API_BASE_URL 默认为 http://54.66.108.150:9001/（双机时取 baasapi 主机 + 端口；与 production.json 一致）。
# 单机：deploy-aws.json 仅顶层 host + remote_path、无 flutterapp/baasapi 分段子段时，server_mgr 单主机双进程。
#
# Python 依赖（与 baasapi/requirements.txt）：
#   · 双机：BaasAPI 机整包 rsync；Flutter/Web 机仅 apk + flutterapp/build/web + serve_web_static/requirements（见 server_mgr）。
#   · 单机：整包 rsync（含 baasapi/）。
#   · 远端安装：`server_mgr.py restart`（本脚本第 5 步）在每台目标机上执行
#     cd remote_path && pip/pip3 install -r baasapi/requirements.txt --user（逻辑同 baasapi/install_on_aws.sh）。
#   · 仅更新依赖不重拉起进程：python3 baasapi/server_mgr.py pip-remote
#
# 环境变量（DevOps）：
#   DEPLOY_CONFIG          部署 JSON，默认 baasapi/deploy-aws.json（可用绝对路径）
#   HZTECH_API_BASE_URL    传给 flutter build 的 API 基址；未设置时由 deploy-aws.json 推导为
#                          {scheme}://{baasapi.host}:{baasapi_port}/（双机时即后端公网地址）
#   FLUTTER_DART_DEFINE_FILE  若已设置且 HZTECH_API_BASE_URL 未设置，则仍走 dart-define-from-file
#   HZTECH_SKIP_BUILD=1    跳过步骤 1–2（移动端 + Web 构建），直接同步与重启
#   数据库迁移（远程 db-sync）：默认不执行；仅当以下任一成立时执行步骤 4：
#     · 命令行: --db / --db-sync / --init-db / -db
#     · HZTECH_DB_SYNC=1（或 true/yes）
#     · HZTECH_SKIP_DB_SYNC=0（显式要求同步，兼容旧脚本）
#   HZTECH_SKIP_DB_SYNC=1  强制跳过（若同时传 --db，则以 --db 为准）
#   HZTECH_POST_DEPLOY_VERIFY=1  部署结束后 curl 探测 BaasAPI /api/health 与 FlutterApp /
#   HZTECH_SKIP_IOS_BUILD  server_mgr 默认不编 iOS；需 IPA 时设为 0（或 false/no）
#
# 依赖：SSH 密钥、Flutter/Android；IPA 需 macOS + Xcode，且显式 HZTECH_SKIP_IOS_BUILD=0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# 默认不执行远程 db-sync；见文件头「数据库迁移」说明
_DB_SYNC_FLAG=0
_argv=()
for _a in "$@"; do
  case "$_a" in
  --db | --db-sync | --init-db | -db)
    _DB_SYNC_FLAG=1
    ;;
  *)
    _argv+=("$_a")
    ;;
  esac
done
# set -u：空数组时 "${_argv[@]}" 在 bash 3.2（macOS 默认）会报 unbound variable
set +u
if [[ ${#_argv[@]} -gt 0 ]]; then
  set -- "${_argv[@]}"
else
  set --
fi
unset _a _argv
set -u

_run_db_sync=0
if [[ "$_DB_SYNC_FLAG" -eq 1 ]]; then
  _run_db_sync=1
elif [[ "${HZTECH_SKIP_DB_SYNC:-}" == "0" ]]; then
  _run_db_sync=1
else
  _sk=$(printf '%s' "${HZTECH_SKIP_DB_SYNC:-}" | tr '[:upper:]' '[:lower:]')
  if [[ "$_sk" == "1" || "$_sk" == "true" || "$_sk" == "yes" ]]; then
    _run_db_sync=0
  else
    _ds=$(printf '%s' "${HZTECH_DB_SYNC:-}" | tr '[:upper:]' '[:lower:]')
    if [[ "$_ds" == "1" || "$_ds" == "true" || "$_ds" == "yes" ]]; then
      _run_db_sync=1
    fi
  fi
fi
unset _DB_SYNC_FLAG _sk _ds

DEPLOY_CONFIG="${DEPLOY_CONFIG:-baasapi/deploy-aws.json}"
if [[ ! -f "$DEPLOY_CONFIG" ]]; then
  echo "错误: 未找到部署配置: $DEPLOY_CONFIG" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "错误: 需要 python3" >&2
  exit 1
fi
# 勿用 PY3：避免与环境中误设的 PY3 冲突；须为可执行绝对/相对路径
_HZTECH_PYTHON3="$(command -v python3)"
[[ -n "$_HZTECH_PYTHON3" ]] || {
  echo "错误: 无法解析 python3 路径" >&2
  exit 1
}

# 一次读取 deploy JSON，供结尾展示 URL / 日志路径（避免硬编码 remote_path）
# 须用 python3 -：若写成 python3 <<PY "$CFG"，bash 会把 CFG 当脚本文件执行，heredoc 不会生效。
eval "$("$_HZTECH_PYTHON3" - "$DEPLOY_CONFIG" <<'PY'
import json, shlex, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    c = json.load(f)
scheme = str(c.get("scheme") or "http")
web_port = int(c.get("flutterapp_port", c.get("web_port", 9000)))
api_port = int(c.get("baasapi_port", c.get("app_port", c.get("web_port", 9001))))
user = str(c.get("user") or "ec2-user")
fa = c.get("flutterapp") if isinstance(c.get("flutterapp"), dict) else {}
ba = c.get("baasapi") if isinstance(c.get("baasapi"), dict) else {}
if not fa:
    fa = c.get("web") if isinstance(c.get("web"), dict) else {}
if not ba:
    ba = c.get("api") if isinstance(c.get("api"), dict) else {}
# 与 server_mgr.has_dual_deploy 一致
dual = (
    "1"
    if isinstance(fa, dict) and isinstance(ba, dict) else "0"
)


def out(name, val):
    print(f"export {name}={shlex.quote(str(val))}")

wh = (fa.get("host") or c.get("host") or "").strip()
ah = (ba.get("host") or "").strip()
wrp = (fa.get("remote_path") or "").strip()
arp = (ba.get("remote_path") or "").strip()
wkey = (fa.get("key") or c.get("key") or "").strip()
akey = (ba.get("key") or c.get("key") or "").strip()
if dual == "0":
    if not ah:
        ah = wh
    if not arp:
        arp = wrp
    if not akey:
        akey = wkey

out("_D_SCHEME", scheme)
out("_D_WEB_HOST", wh)
out("_D_API_HOST", ah)
out("_D_WEB_PORT", web_port)
out("_D_API_PORT", api_port)
out("_D_WEB_RP", wrp)
out("_D_API_RP", arp)
out("_D_WEB_KEY", wkey)
out("_D_API_KEY", akey)
out("_D_USER", user)
out("_D_DUAL", dual)
PY
)"

# 与 deploy-aws.json 中 BaasAPI 监听地址一致（双机时即后端 host）。仅当「未 export」时自动填充；
# 若需完全使用 dart-define 文件中的 API_BASE_URL，可执行: export HZTECH_API_BASE_URL="" （空串会走 server_mgr 的文件分支）
if [ "${HZTECH_API_BASE_URL+x}" = "" ]; then
  export HZTECH_API_BASE_URL="${_D_SCHEME}://${_D_API_HOST}:${_D_API_PORT}/"
fi
export FLUTTER_DART_DEFINE_FILE="${FLUTTER_DART_DEFINE_FILE:-flutterapp/dart_defines/production.json}"
export HZTECH_SKIP_IOS_BUILD="${HZTECH_SKIP_IOS_BUILD:-1}"
# 数据库默认使用 PostgreSQL；如有特殊需要可在执行前覆盖 HZTECH_DB_BACKEND
export HZTECH_DB_BACKEND="${HZTECH_DB_BACKEND:-postgresql}"

echo "=============================================="
echo "  Ops 部署：Flutter 构建 → AWS 同步 → 服务重启"
echo "  配置: $DEPLOY_CONFIG"
if [[ "$_D_DUAL" == "1" ]]; then
  echo "  双机: Web@${_D_WEB_HOST}  API@${_D_API_HOST}"
else
  echo "  单机: ${_D_WEB_HOST}（Web ${_D_WEB_PORT}  API ${_D_API_PORT}）"
fi
echo "  构建 API_BASE_URL: ${HZTECH_API_BASE_URL}"
echo "  缺省 BaasAPI（App/Web → 后端；与 deploy-aws.json 中 baasapi 一致）:"
echo "    Debug 构建默认:   ${HZTECH_API_BASE_URL}"
echo "    Release 构建默认: ${HZTECH_API_BASE_URL}"
echo "=============================================="

if [[ "${HZTECH_SKIP_BUILD:-0}" == "1" ]]; then
  printf '\n'
  echo "=== （已跳过构建 HZTECH_SKIP_BUILD=1）==="
else
  printf '\n'
  echo "=== 1/5 构建 Flutter 移动端 (release APK → apk/hztech-app-release.apk；iOS IPA 默认跳过) ==="
  "$_HZTECH_PYTHON3" "$PROJECT_ROOT/baasapi/server_mgr.py" build
  echo "  APK: $PROJECT_ROOT/apk/hztech-app-release.apk"
  echo "  IPA: 默认不构建；需要时 export HZTECH_SKIP_IOS_BUILD=0 后再运行（产物 ipa/）"

  printf '\n'
  echo "=== 2/5 构建 Flutter Web (release) ==="
  if "$_HZTECH_PYTHON3" "$PROJECT_ROOT/baasapi/server_mgr.py" build-web; then
    echo "  Web: $PROJECT_ROOT/flutterapp/build/web/"
  else
    echo "  （Web 构建失败或跳过；远端 Web 静态可能 503，API 仍可用）" >&2
  fi
fi

printf '\n'
echo "=== 3/5 上传到 AWS（rsync，--no-start）==="
"$_HZTECH_PYTHON3" "$PROJECT_ROOT/baasapi/server_mgr.py" deploy --no-start

if [[ "$_run_db_sync" -eq 1 ]]; then
  printf '\n'
  echo "=== 4/5 同步远程数据库（用户迁移）==="
  "$_HZTECH_PYTHON3" "$PROJECT_ROOT/baasapi/server_mgr.py" db-sync
else
  printf '\n'
  echo "=== 4/5 跳过远程 DB（默认不迁移；需要时请传 --db 或 HZTECH_DB_SYNC=1）==="
fi
unset _run_db_sync

printf '\n'
echo "=== 5/5 重启 AWS 后台服务 ==="
"$_HZTECH_PYTHON3" "$PROJECT_ROOT/baasapi/server_mgr.py" restart

printf '\n'
echo "=============================================="
echo "  部署完成（FlutterApp + BaasAPI）"
echo "  缺省 BaasAPI（App/Web → 后端）: ${HZTECH_API_BASE_URL}"
echo "    Debug / Release 构建均使用上述 API 根地址（见 production.json / dart-define）"
if [[ "$_D_DUAL" == "1" ]]; then
  echo "  FlutterApp（Web 静态）: ${_D_SCHEME}://${_D_WEB_HOST}:${_D_WEB_PORT}/"
  echo "  BaasAPI（后端）:       ${_D_SCHEME}://${_D_API_HOST}:${_D_API_PORT}/"
  if [[ -n "$_D_WEB_RP" ]]; then
    echo "  日志 FlutterApp: ${_D_WEB_RP}/web_static.log"
  fi
  if [[ -n "$_D_API_RP" ]]; then
    echo "  日志 BaasAPI: ${_D_API_RP}/server.log"
  fi
  if [[ -n "$_D_WEB_KEY" && -n "$_D_WEB_HOST" ]]; then
    echo "  SSH FlutterApp: ssh -i \"${_D_WEB_KEY}\" ${_D_USER}@${_D_WEB_HOST}"
  fi
  if [[ -n "$_D_API_KEY" && -n "$_D_API_HOST" ]]; then
    echo "  SSH BaasAPI: ssh -i \"${_D_API_KEY}\" ${_D_USER}@${_D_API_HOST}"
  fi
else
  echo "  FlutterApp: ${_D_SCHEME}://${_D_WEB_HOST}:${_D_WEB_PORT}/"
  echo "  BaasAPI:    ${_D_SCHEME}://${_D_WEB_HOST}:${_D_API_PORT}/"
  if [[ -n "$_D_WEB_RP" ]]; then
    echo "  日志: ${_D_WEB_RP}/server.log  ${_D_WEB_RP}/web_static.log"
  fi
fi
echo "=============================================="

if [[ "${HZTECH_POST_DEPLOY_VERIFY:-0}" == "1" ]]; then
  printf '\n'
  echo "=== 部署后探测（HZTECH_POST_DEPLOY_VERIFY=1）==="
  _curl_ok() {
    local url="$1"
    local name="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 15 "$url" || echo "000")
    if [[ "$code" == "200" || "$code" == "503" ]]; then
      echo "  OK $name -> HTTP $code ($url)"
    else
      echo "  WARN $name -> HTTP $code ($url)" >&2
    fi
  }
  if [[ "$_D_DUAL" == "1" ]]; then
    _curl_ok "${_D_SCHEME}://${_D_API_HOST}:${_D_API_PORT}/api/health" "BaasAPI health"
    _curl_ok "${_D_SCHEME}://${_D_WEB_HOST}:${_D_WEB_PORT}/" "FlutterApp /"
  else
    _curl_ok "${_D_SCHEME}://${_D_WEB_HOST}:${_D_API_PORT}/api/health" "BaasAPI health"
    _curl_ok "${_D_SCHEME}://${_D_WEB_HOST}:${_D_WEB_PORT}/" "FlutterApp /"
  fi
fi
