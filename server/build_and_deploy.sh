#!/usr/bin/env bash
# 一键：编译 App 为 APK → 部署服务端到 AWS → 上传 APK 到 AWS
# 依赖：已配置 server/deploy-aws.json，本机可 SSH 到 AWS，且已安装 Gradle Wrapper（gradlew）
set -e
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

echo "=== 1) 编译 APK（优先 Flutter） ==="
if [[ -d "$PROJECT_ROOT/flutter_app" ]]; then
  python3 "$PROJECT_ROOT/server/server_mgr.py" build || true
elif [[ -f "$PROJECT_ROOT/gradlew" ]] && [[ -f "$PROJECT_ROOT/gradle/wrapper/gradle-wrapper.jar" ]]; then
  chmod +x "$PROJECT_ROOT/gradlew"
  python3 "$PROJECT_ROOT/server/server_mgr.py" build || true
else
  echo "未找到 flutter_app 或 gradlew，跳过编译。可将 APK 放入 apk/ 后重新执行。"
fi

echo ""
echo "=== 2) 部署服务端并上传到 AWS ==="
python3 "$PROJECT_ROOT/server/server_mgr.py" deploy

echo ""
echo "完成。访问 http://<host>:5000 下载 APK 或查看服务。"
