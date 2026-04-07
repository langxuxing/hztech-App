#!/usr/bin/env bash
# 启动 Flutter DevTools（需先在本机用 flutter run 或 F5 启动 App 调试）
# 用法：在 flutterapp 目录下执行 ./open_devtools.sh
set -e
cd "$(dirname "$0")"
flutter pub global activate devtools 2>/dev/null || true
echo "正在打开 Flutter DevTools，请在浏览器中连接已运行的 Flutter 应用..."
flutter pub global run devtools
