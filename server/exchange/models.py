# -*- coding: utf-8 -*-
"""
交易所与订单模型，与 qtraderweb exchange_manager 接口一致。
"""
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Any, Dict, Optional


class ExchangeType(Enum):
    OKX = "okx"
    BINANCE = "binance"
    ALPACA = "alpaca"


class OrderType(Enum):
    MARKET = "market"
    LIMIT = "limit"


class OrderSide(Enum):
    BUY = "buy"
    SELL = "sell"


class OrderStatus(Enum):
    PENDING = "pending"
    OPEN = "open"
    FILLED = "filled"
    CANCELLED = "cancelled"
    REJECTED = "rejected"
    EXPIRED = "expired"


@dataclass
class ExchangeConfig:
    api_key: str
    api_secret: str
    passphrase: str = ""
    sandbox: bool = False
    config_path: Optional[Path] = None


@dataclass
class OrderRequest:
    id: str
    exchange: ExchangeType
    symbol: str
    side: OrderSide
    order_type: OrderType
    quantity: float
    price: Optional[float] = None


@dataclass
class OrderResult:
    request_id: str
    exchange: ExchangeType
    status: OrderStatus
    success: bool
    symbol: str
    side: OrderSide
    order_type: OrderType
    quantity: float
    price: Optional[float] = None
    order_id: Optional[str] = None
    filled_quantity: Optional[float] = None
    fee: Optional[float] = None
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None
    error_message: Optional[str] = None
    error_code: Optional[str] = None
