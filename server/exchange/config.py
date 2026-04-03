# -*- coding: utf-8 -*-
"""
OKX 交易所配置：从 Accounts 的 OKX JSON 读取，与 okx.py 行为一致。
供 ExchangeManager 在无 QTrader 时使用。
"""
from pathlib import Path
from typing import List, Optional

from . import okx
from .models import ExchangeConfig, ExchangeType as ModelExchangeType

# 默认配置目录：server/Accounts
_DEFAULT_CONFIG_DIR = Path(__file__).resolve().parent.parent / "Accounts"


def _get_config_dir() -> Path:
    return Path(__file__).resolve().parent.parent / "Accounts"


def get_default_okx_config_path() -> Optional[Path]:
    """返回默认 OKX 配置路径（存在则返回）。"""
    config_dir = _get_config_dir()
    path = okx.get_default_config_path(config_dir)
    return path if path.exists() else None


def get_enabled_exchanges() -> List[ModelExchangeType]:
    """返回已启用的交易所列表。当前仅 OKX：若存在 OKX 配置则返回 [OKX]。"""
    path = get_default_okx_config_path()
    if path and okx.load_okx_config(path):
        return [ModelExchangeType.OKX]
    return []


def get_exchange_config(exchange_type: ModelExchangeType) -> Optional[ExchangeConfig]:
    """根据交易所类型返回配置。OKX 从 okx.load_okx_config 转换。"""
    if exchange_type != ModelExchangeType.OKX:
        return None
    path = get_default_okx_config_path()
    if not path:
        return None
    cfg = okx.load_okx_config(path)
    if not cfg or not (cfg.get("key") and cfg.get("secret")):
        return None
    return ExchangeConfig(
        api_key=cfg.get("key") or "",
        api_secret=cfg.get("secret") or "",
        passphrase=cfg.get("passphrase") or "",
        sandbox=bool(cfg.get("sandbox")),
        config_path=path,
    )


def get_trading_config() -> dict:
    """返回交易配置（如 dry_run）。当前返回默认。"""
    return {"dry_run": False}
