#!/usr/bin/env bash
# 供 deploy2Local.sh / deploy2AWS.sh 在无参数交互模式下 source。
# 依赖：已设置 PROJECT_ROOT；由 deploy_common.sh 的 hztech_need_deploy_interactive 决定是否调用。

hztech_run_local_wizard() {
  HZTECH_WIZARD_ARGS=()
  cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 🖥️  deploy2Local.sh — 本地开发（→ baasapi/deploy_orchestrator.py local）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📌 作用概要
  · 🐍 可选：本机 install_python_deps.sh
  · 📦 可选：Flutter 构建（Web / Android / iOS；Web 始终 release）
  · 🗄️ 可选：本地 init_db（--db）
  · 🚀 默认最后 exec baasapi/run_local.sh（本机 API + Web 静态）

💡 说明：若已设置 HZTECH_SSH_INSTALL_PG_AWS_ALPHA=1，确认后仍会先执行远端 PG 安装脚本。

⏭️  跳过本向导
    ./deploy2Local.sh --skip-build
    ./deploy2Local.sh --build web --no-start
  或：CI=1、HZTECH_DEPLOY_YES=1、HZTECH_DEPLOY_NONINTERACTIVE=1

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🧩 Flutter 编译组合（对应 --build）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1) 🌐 仅 Web
  2) 📱 仅 Android
  3) 🍎 仅 iOS
  4) 🌐📱 Web + Android（默认，android,web）
  5) 🌐📱🍎 Web + Android + iOS（android,web,ios）
  6) ⏭️  跳过构建（--skip-build，仍执行 pip 等后续阶段）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔧 移动端模式（仅影响 Android；未选 Android 则不问）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  r) release（默认，hztech-app-release.apk）
  d) debug

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🗄️ 数据库
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  n) 不执行本地 init_db（默认）
  y) 执行本地迁移（--db）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🚀 启动
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Y) 结束后启动 run_local.sh（默认）
  n) 仅构建/依赖/DB，不启动（--no-start）

EOF
  local bchoice fmode dbopt startopt
  while true; do
    printf "请选择编译组合 [1-6]（默认 4）: "
    read -r bchoice
    bchoice=${bchoice:-4}
    case "$bchoice" in
      1) HZTECH_WIZARD_ARGS+=(--build web) ;;
      2) HZTECH_WIZARD_ARGS+=(--build android) ;;
      3) HZTECH_WIZARD_ARGS+=(--build ios) ;;
      4) HZTECH_WIZARD_ARGS+=(--build android,web) ;;
      5) HZTECH_WIZARD_ARGS+=(--build android,web,ios) ;;
      6) HZTECH_WIZARD_ARGS+=(--skip-build) ;;
      *) echo "无效输入，请输入 1-6。"; continue ;;
    esac
    break
  done
  if [[ "$bchoice" != "6" ]]; then
    printf "移动端构建模式 [r/d]（默认 r）: "
    read -r fmode
    fmode=${fmode:-r}
    case "$fmode" in
      d | D) HZTECH_WIZARD_ARGS+=(--flutter-mode debug) ;;
      *) ;;
    esac
  fi
  printf "是否执行本地数据库 init_db [y/N]: "
  read -r dbopt
  case "$dbopt" in
    y | Y | yes | YES) HZTECH_WIZARD_ARGS+=(--db) ;;
  esac
  printf "结束后是否启动本机 API+Web [Y/n]: "
  read -r startopt
  startopt=${startopt:-y}
  case "$startopt" in
    n | N | no | NO) HZTECH_WIZARD_ARGS+=(--no-start) ;;
  esac

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 即将执行"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  python3 baasapi/deploy_orchestrator.py local ${HZTECH_WIZARD_ARGS[*]}"
  echo ""
  printf "确认执行？[y/N] "
  read -r yn
  case "$yn" in
    y | Y | yes | YES) return 0 ;;
    *)
      echo "已取消。"
      return 1
      ;;
  esac
}

# AWS 向导在设置默认 export 之后调用，可覆盖 HZTECH_* 并生成传给 orchestrator aws 的参数。
hztech_run_aws_wizard() {
  HZTECH_WIZARD_ARGS=()
  cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 🚀 deploy2AWS.sh — AWS 部署（→ baasapi/deploy_orchestrator.py aws）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📌 作用概要
  · 🖥️  本机：按选项执行 Flutter 构建（Web / Android / iOS 组合）
  · 📤 同步：rsync 到 BaasAPI 机（如 aws-alpha）与 Flutter 静态机（如 aws-defi），见 baasapi/deploy-aws.json
  · 🎯 脚本默认：只构建 Web + 全量 rsync；不编 Android、不上传 APK（HZTECH_SKIP_MOBILE_BUILD=1 等）

⏭️  跳过本向导
  直接带参数执行，例如：
    ./deploy2AWS.sh --skip-build
    ./deploy2AWS.sh --db
  或导出：CI=1、HZTECH_DEPLOY_YES=1、HZTECH_DEPLOY_NONINTERACTIVE=1

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🧩 部署 / 编译组合（选 1–5）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1) 🌐 默认：仅构建 Web → 全量 rsync；❌ 不构建 APK、❌ 不同步 APK
  2) 📱 构建 Web + Android（APK）→ 全量 rsync ✅ 并同步 APK 到远端
  3) 🍎 在 2 的基础上增加本机 iOS 产物（需允许 iOS 构建环境）
  4) ⏭️  跳过全部 Flutter 构建（使用已有产物；等同 --skip-build）
  5) 📲 仅上传 release APK（HZTECH_DEPLOY_APK_ONLY=1；编排器会跳过 Web 与全量 rsync）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔧 Flutter 移动端模式（选项 2 / 3 / 5 且含 Android 时询问）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  r) release（默认）
  d) debug

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🗄️ 数据库
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  n) 不做远端 db-sync（默认）
  y) 部署后远端 db-sync（--db）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔄 上传完成后
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Y) 远端 restart + pip 等（编排器阶段 7–8；默认）
  n) 不执行 restart（--no-start）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔍 部署结束
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Y) HTTP 健康检查（默认，等同 HZTECH_POST_DEPLOY_VERIFY=1）
  n / k) 跳过探测（本次 HZTECH_POST_DEPLOY_VERIFY=0）

EOF
  local mode fmode dbopt restartopt verifyopt
  while true; do
    printf "请选择部署模式 [1-5]（默认 1）: "
    read -r mode
    mode=${mode:-1}
    case "$mode" in
      1)
        export HZTECH_SKIP_MOBILE_BUILD=1
        export HZTECH_DEPLOY_SKIP_APK_SYNC=1
        export HZTECH_DEPLOY_APK_ONLY=0
        HZTECH_WIZARD_ARGS+=(--build android,web)
        ;;
      2)
        export HZTECH_SKIP_MOBILE_BUILD=0
        export HZTECH_DEPLOY_SKIP_APK_SYNC=0
        export HZTECH_DEPLOY_APK_ONLY=0
        HZTECH_WIZARD_ARGS+=(--build android,web)
        ;;
      3)
        export HZTECH_SKIP_MOBILE_BUILD=0
        export HZTECH_DEPLOY_SKIP_APK_SYNC=0
        export HZTECH_DEPLOY_APK_ONLY=0
        HZTECH_WIZARD_ARGS+=(--build android,web,ios)
        ;;
      4)
        export HZTECH_DEPLOY_APK_ONLY=0
        HZTECH_WIZARD_ARGS+=(--skip-build)
        ;;
      5)
        export HZTECH_DEPLOY_APK_ONLY=1
        export HZTECH_SKIP_MOBILE_BUILD=0
        export HZTECH_DEPLOY_SKIP_APK_SYNC=0
        HZTECH_WIZARD_ARGS+=(--build android)
        ;;
      *) echo "无效输入，请输入 1-5。"; continue ;;
    esac
    break
  done

  if [[ "$mode" == "2" || "$mode" == "3" || "$mode" == "5" ]]; then
    printf "Android 构建模式 [r/d]（默认 r）: "
    read -r fmode
    fmode=${fmode:-r}
    case "$fmode" in
      d | D) HZTECH_WIZARD_ARGS+=(--flutter-mode debug) ;;
      *) ;;
    esac
  fi

  printf "是否部署后远端数据库同步 --db [y/N]: "
  read -r dbopt
  case "$dbopt" in
    y | Y | yes | YES) HZTECH_WIZARD_ARGS+=(--db) ;;
  esac
  printf "上传后是否执行远端 restart [Y/n]: "
  read -r restartopt
  restartopt=${restartopt:-y}
  case "$restartopt" in
    n | N | no | NO) HZTECH_WIZARD_ARGS+=(--no-start) ;;
  esac
  printf "部署结束后是否 HTTP 探测 [Y/n/k]（k=跳过）: "
  read -r verifyopt
  verifyopt=${verifyopt:-y}
  case "$verifyopt" in
    n | N | no | NO | k | K) export HZTECH_POST_DEPLOY_VERIFY=0 ;;
    *) export HZTECH_POST_DEPLOY_VERIFY=1 ;;
  esac

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 即将执行（环境变量已按选项调整）"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  python3 baasapi/deploy_orchestrator.py aws ${HZTECH_WIZARD_ARGS[*]}"
  echo ""
  echo "  相关环境变量（摘要）："
  echo "    HZTECH_SKIP_MOBILE_BUILD=${HZTECH_SKIP_MOBILE_BUILD:-}"
  echo "    HZTECH_DEPLOY_SKIP_APK_SYNC=${HZTECH_DEPLOY_SKIP_APK_SYNC:-}"
  echo "    HZTECH_DEPLOY_APK_ONLY=${HZTECH_DEPLOY_APK_ONLY:-}"
  echo "    HZTECH_POST_DEPLOY_VERIFY=${HZTECH_POST_DEPLOY_VERIFY:-}"
  echo ""
  printf "确认执行？[y/N] "
  read -r yn
  case "$yn" in
    y | Y | yes | YES) return 0 ;;
    *)
      echo "已取消。"
      return 1
      ;;
  esac
}
