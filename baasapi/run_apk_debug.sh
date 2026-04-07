#!/usr/bin/env bash
# 本地 APK 调试：在真机/模拟器上跑 debug 版，用 Chrome（Flutter DevTools）调试
# 用法：在项目根目录执行 ./baasapi/run_apk_debug.sh
# 依赖：Flutter、Android SDK、已连接设备或已启动模拟器
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLUTTER_APP="$PROJECT_ROOT/flutterapp"
cd "$FLUTTER_APP"
# Debug 构建固定注入本机 API（与 prefs 中 Debug 默认一致；真机请改用电脑局域网 IP，见 prefs 注释）
DART_DEFINES_LOCAL=(--dart-define-from-file=dart_defines/local.json)

# 可选：仅构建 debug APK 不运行（脚本后加 --build-only）
BUILD_ONLY=""
if [ "${1:-}" = "--build-only" ]; then
  BUILD_ONLY=1
fi

echo "=============================================="
echo "  本地 APK 调试（Chrome DevTools）"
echo "=============================================="
echo ""

if [ -n "$BUILD_ONLY" ]; then
  echo "=== 仅构建 debug APK ==="
  flutter build apk --debug "${DART_DEFINES_LOCAL[@]}"
  APK_PATH="$FLUTTER_APP/build/app/outputs/apk/debug/app-debug.apk"
  if [ -f "$APK_PATH" ]; then
    echo "  输出: $APK_PATH"
    echo "  安装到设备: adb install -r $APK_PATH"
    echo "  然后在设备上打开 App，Chrome 访问 chrome://inspect 可调试 WebView（若有）；"
    echo "  或使用: flutter attach 连接后获取 DevTools 链接在 Chrome 中打开。"
  fi
  exit 0
fi

echo "=== 检查设备/模拟器 ==="
if ! flutter devices 2>/dev/null | grep -q "connected"; then
  echo "  未检测到已连接设备或模拟器。请："
  echo "  - 连接真机并开启 USB 调试，或"
  echo "  - 启动 Android 模拟器（Android Studio -> AVD）"
  echo "  然后重新运行: ./baasapi/run_apk_debug.sh"
  exit 1
fi
flutter devices
echo ""

echo "=== 运行 Debug 版（安装并启动 App）==="
echo "  终端会输出 Flutter DevTools 链接，在 Chrome 中打开该链接即可调试。"
echo "  若未自动弹出，在终端中查找类似："
echo "    The Flutter DevTools debugger and profiler ... is available at: http://127.0.0.1:xxxxx"
echo ""

exec flutter run "${DART_DEFINES_LOCAL[@]}"
