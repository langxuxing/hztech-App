# -*- coding: utf-8 -*-
"""
QTrader 路径配置。无 QTrader 时为占位实现，不修改 sys.path。
"""
from pathlib import Path

QTRADER_CORE_PATH: Path = Path(__file__).resolve().parent


def setup_qtrader_path() -> None:
    """若需加载 QTrader 核心，可在此将 QTrader 根目录加入 sys.path。当前为空实现。"""
    pass
