#!/usr/bin/env bash
# 在无法升级全局 pytest-asyncio 时，禁用 setuptools 自动加载插件（本项目 test 未使用 asyncio）。
# 若需加载其它 pytest 插件，请先: pip install -U 'pytest-asyncio>=0.24'，再直接用: python3 -m pytest test/
# test_random_bot_start_stop 使用 capsys.disabled()，日志默认即输出到终端，无需 -s
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PYTEST_DISABLE_PLUGIN_AUTOLOAD="${PYTEST_DISABLE_PLUGIN_AUTOLOAD:-1}"
exec python3 -m pytest test "$@"
