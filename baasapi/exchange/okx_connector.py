#!/usr/bin/env python
# -*- coding: utf-8 -*-

"""
交易所管理器
Exchange Manager Module

集成 QTrader 的 CCXTExchange，支持多交易所并发执行
"""

import asyncio
import logging
import sys
from datetime import datetime
from typing import Dict, List, Optional, Any, Tuple
from concurrent.futures import ThreadPoolExecutor

# 在导入 QTrader 模块之前设置日志级别
# 降低 QTrader 模块的日志级别，减少 API 调用失败的噪音
qtrader_logger = logging.getLogger('QTrader')
qtrader_logger.setLevel(logging.WARNING)

# 使用统一路径配置
from .path_config import setup_qtrader_path, QTRADER_CORE_PATH
setup_qtrader_path()

try:
    # 使用新的统一Exchange接口
    from core.exchange import (
        get_exchange_manager,
        ExchangeType,
        ExchangeManager
    )
    from core.engine.exchange import (
        CCXTExchange,
        OrderType,
        OrderSide,
        OrderStatus
    )
    
    logging.debug("成功导入 QTrader 核心模块（使用统一Exchange接口）")
    HAS_EXCHANGE_MANAGER = True
except (ImportError, Exception) as e:
    logging.debug("QTrader 核心模块未可用（可选依赖）: %s", e)
    HAS_EXCHANGE_MANAGER = False
    
    # 如果无法导入，定义基本类型
    class ExchangeType:
        OKX = "okx"
        BINANCE = "binance"
        ALPACA = "alpaca"
    
    class OrderType:
        MARKET = "market"
        LIMIT = "limit"
    
    class OrderSide:
        BUY = "buy"
        SELL = "sell"
    
    class OrderStatus:
        OPEN = "open"
        FILLED = "filled"
        CANCELLED = "cancelled"
        REJECTED = "rejected"
    
    # 定义占位类
    class CCXTExchange:
        def __init__(self, *args, **kwargs):
            raise ImportError("无法导入 CCXTExchange，请确保 QTrader 核心模块可用")

from .config import get_exchange_config, get_enabled_exchanges, get_trading_config
from .models import (
    ExchangeConfig, OrderRequest, OrderResult, ExchangeType as ModelExchangeType,
    OrderType as ModelOrderType, OrderSide as ModelOrderSide, OrderStatus as ModelOrderStatus
)
from . import okx as _okx_module

logger = logging.getLogger(__name__)

# OKX 使用本地 okx 模块时的占位：exchange 为 None 表示走 okx.py
_OKX_NATIVE_SENTINEL = None


class ExchangeManager:
    """交易所管理器（包装类，使用core/exchange统一管理器）"""
    
    def __init__(self):
        """初始化交易所管理器"""
        if HAS_EXCHANGE_MANAGER:
            # 使用新的统一ExchangeManager
            self._core_manager = get_exchange_manager()
            logger.debug("使用统一的ExchangeManager")
        else:
            # 降级：无 QTrader 时用本地 okx 模块实现 OKX 已有功能（余额/持仓/行情）
            self.exchanges: Dict[ModelExchangeType, Any] = {}  # OKX 可为 None，表示用 okx.py
            self.exchange_configs: Dict[ModelExchangeType, ExchangeConfig] = {}
            self.trading_config = get_trading_config()
            self.executor = ThreadPoolExecutor(max_workers=10)
            
            # 初始化交易所连接
            self._initialize_exchanges()
            
            logger.debug(
                "交易所管理器初始化完成（旧实现），已连接 %s 个交易所",
                len(self.exchanges),
            )
    
    def _initialize_exchanges(self) -> None:
        """初始化所有启用的交易所；OKX 无 QTrader 时用 okx.py 实现已有功能。"""
        enabled_exchanges = get_enabled_exchanges()
        
        for exchange_type in enabled_exchanges:
            try:
                config = get_exchange_config(exchange_type)
                if not config:
                    logger.warning(f"{exchange_type.value} 交易所配置未找到")
                    continue
                
                # OKX 且无 QTrader 时：用 okx.py 实现余额/持仓/行情
                if exchange_type == ModelExchangeType.OKX and not HAS_EXCHANGE_MANAGER:
                    self.exchanges[exchange_type] = _OKX_NATIVE_SENTINEL
                    self.exchange_configs[exchange_type] = config
                    logger.debug("OKX 使用本地 okx 模块（余额/持仓/行情）")
                    continue
                
                # 创建交易所实例
                exchange = self._create_exchange_instance(exchange_type, config)
                if exchange:
                    self.exchanges[exchange_type] = exchange
                    self.exchange_configs[exchange_type] = config
                    logger.debug("%s 交易所连接成功", exchange_type.value)
                else:
                    logger.error(f"{exchange_type.value} 交易所连接失败")
                    
            except Exception as e:
                logger.error(f"初始化 {exchange_type.value} 交易所失败: {e}")
    
    def _create_exchange_instance(self, exchange_type: ModelExchangeType, config: ExchangeConfig) -> Optional[CCXTExchange]:
        """创建交易所实例（旧实现，向后兼容）"""
        try:
            # 转换交易所类型
            qtrader_exchange_type = self._convert_exchange_type(exchange_type)
            
            # 创建 CCXTExchange 实例
            exchange = CCXTExchange(
                exchange_type=qtrader_exchange_type,
                api_key=config.api_key,
                secret=config.api_secret,
                password=config.passphrase or "",
                sandbox=config.sandbox,
                rate_limit=100,
                timeout=30000
            )
            
            return exchange
            
        except Exception as e:
            logger.error(f"创建 {exchange_type.value} 交易所实例失败: {e}")
            return None
    
    def _convert_exchange_type(self, exchange_type: ModelExchangeType) -> ExchangeType:
        """转换交易所类型"""
        type_mapping = {
            ModelExchangeType.OKX: ExchangeType.OKX,
            ModelExchangeType.BINANCE: ExchangeType.BINANCE,
            ModelExchangeType.ALPACA: ExchangeType.ALPACA
        }
        return type_mapping.get(exchange_type, ExchangeType.OKX)
    
    def _convert_order_type(self, order_type: ModelOrderType) -> OrderType:
        """转换订单类型"""
        type_mapping = {
            ModelOrderType.MARKET: OrderType.MARKET,
            ModelOrderType.LIMIT: OrderType.LIMIT
        }
        return type_mapping.get(order_type, OrderType.MARKET)
    
    def _convert_order_side(self, order_side: ModelOrderSide) -> OrderSide:
        """转换订单方向"""
        side_mapping = {
            ModelOrderSide.BUY: OrderSide.BUY,
            ModelOrderSide.SELL: OrderSide.SELL
        }
        return side_mapping.get(order_side, OrderSide.BUY)
    
    def _convert_order_status(self, status: str) -> ModelOrderStatus:
        """转换订单状态"""
        status_mapping = {
            "open": ModelOrderStatus.OPEN,
            "closed": ModelOrderStatus.FILLED,
            "canceled": ModelOrderStatus.CANCELLED,
            "rejected": ModelOrderStatus.REJECTED,
            "expired": ModelOrderStatus.EXPIRED
        }
        return status_mapping.get(status.lower(), ModelOrderStatus.PENDING)
    
    async def execute_order(self, order_request: OrderRequest) -> OrderResult:
        """
        执行单个订单
        
        Args:
            order_request: 订单请求
            
        Returns:
            OrderResult: 订单执行结果
        """
        exchange = self.exchanges.get(order_request.exchange)
        if exchange is _OKX_NATIVE_SENTINEL:
            return OrderResult(
                request_id=order_request.id,
                exchange=order_request.exchange,
                status=ModelOrderStatus.REJECTED,
                success=False,
                symbol=order_request.symbol,
                side=order_request.side,
                order_type=order_request.order_type,
                quantity=order_request.quantity,
                price=order_request.price,
                error_message="OKX 本地模块仅支持余额/持仓/行情查询，不支持下单",
                error_code="OKX_READ_ONLY"
            )
        if not exchange:
            return OrderResult(
                request_id=order_request.id,
                exchange=order_request.exchange,
                status=ModelOrderStatus.REJECTED,
                success=False,
                symbol=order_request.symbol,
                side=order_request.side,
                order_type=order_request.order_type,
                quantity=order_request.quantity,
                price=order_request.price,
                error_message=f"交易所 {order_request.exchange.value} 未连接",
                error_code="EXCHANGE_NOT_CONNECTED"
            )
        
        try:
            # 转换订单参数
            ccxt_order_type = self._convert_order_type(order_request.order_type)
            ccxt_order_side = self._convert_order_side(order_request.side)
            
            # 执行订单
            if self.trading_config.get("dry_run", False):
                # 模拟交易模式
                result = await self._simulate_order(order_request)
            else:
                # 真实交易
                result = await self._execute_real_order(exchange, order_request, ccxt_order_type, ccxt_order_side)
            
            return result
            
        except Exception as e:
            logger.error(f"执行订单失败: {e}")
            return OrderResult(
                request_id=order_request.id,
                exchange=order_request.exchange,
                status=ModelOrderStatus.REJECTED,
                success=False,
                symbol=order_request.symbol,
                side=order_request.side,
                order_type=order_request.order_type,
                quantity=order_request.quantity,
                price=order_request.price,
                error_message=str(e),
                error_code="EXECUTION_ERROR"
            )
    
    async def _execute_real_order(self, exchange: CCXTExchange, order_request: OrderRequest, 
                                 ccxt_order_type: OrderType, ccxt_order_side: OrderSide) -> OrderResult:
        """执行真实订单"""
        try:
            # 创建订单
            order = await exchange.create_order(
                symbol=order_request.symbol,
                order_type=ccxt_order_type,
                side=ccxt_order_side,
                amount=order_request.quantity,
                price=order_request.price
            )
            
            # 转换结果
            return OrderResult(
                request_id=order_request.id,
                exchange=order_request.exchange,
                order_id=order.id,
                status=self._convert_order_status(order.status.value),
                success=order.status.value in ["open", "closed"],
                symbol=order.symbol,
                side=ModelOrderSide(order.side.value),
                order_type=ModelOrderType(order.type.value),
                quantity=order.amount,
                price=order.price,
                filled_quantity=order.filled,
                fee=order.fee,
                created_at=order.timestamp,
                updated_at=datetime.now()
            )
            
        except Exception as e:
            logger.error(f"创建订单失败: {e}")
            raise
    
    async def _simulate_order(self, order_request: OrderRequest) -> OrderResult:
        """模拟订单执行"""
        # 模拟订单ID
        simulated_order_id = f"SIM_{int(datetime.now().timestamp() * 1000)}"
        
        # 模拟成交价格（使用请求价格或随机价格）
        simulated_price = order_request.price or 50000.0
        
        # 模拟手续费
        simulated_fee = simulated_price * order_request.quantity * 0.001
        
        return OrderResult(
            request_id=order_request.id,
            exchange=order_request.exchange,
            order_id=simulated_order_id,
            status=ModelOrderStatus.FILLED,
            success=True,
            symbol=order_request.symbol,
            side=order_request.side,
            order_type=order_request.order_type,
            quantity=order_request.quantity,
            price=simulated_price,
            filled_quantity=order_request.quantity,
            fee=simulated_fee,
            created_at=datetime.now(),
            updated_at=datetime.now()
        )
    
    async def execute_orders_concurrent(self, order_requests: List[OrderRequest]) -> List[OrderResult]:
        """
        并发执行多个订单
        
        Args:
            order_requests: 订单请求列表
            
        Returns:
            List[OrderResult]: 订单执行结果列表
        """
        if not order_requests:
            return []
        
        # 创建并发任务
        tasks = [self.execute_order(request) for request in order_requests]
        
        # 并发执行
        results = await asyncio.gather(*tasks, return_exceptions=True)
        
        # 处理异常结果
        processed_results = []
        for i, result in enumerate(results):
            if isinstance(result, Exception):
                logger.error(f"订单 {order_requests[i].id} 执行异常: {result}")
                processed_results.append(OrderResult(
                    request_id=order_requests[i].id,
                    exchange=order_requests[i].exchange,
                    status=ModelOrderStatus.REJECTED,
                    success=False,
                    symbol=order_requests[i].symbol,
                    side=order_requests[i].side,
                    order_type=order_requests[i].order_type,
                    quantity=order_requests[i].quantity,
                    price=order_requests[i].price,
                    error_message=str(result),
                    error_code="CONCURRENT_EXECUTION_ERROR"
                ))
            else:
                processed_results.append(result)
        
        return processed_results
    
    def _okx_config_path(self) -> Optional[Any]:
        """OKX 使用的配置路径（用于 okx.py 的 config_path 参数）。"""
        cfg = self.exchange_configs.get(ModelExchangeType.OKX)
        return getattr(cfg, "config_path", None) if cfg else None

    async def get_balance(self, exchange_type: ModelExchangeType) -> Dict[str, float]:
        """
        获取交易所余额（OKX 本地模块返回 total_eq/avail_eq/upl）
        """
        exchange = self.exchanges.get(exchange_type)
        if exchange_type == ModelExchangeType.OKX and exchange is _OKX_NATIVE_SENTINEL:
            loop = asyncio.get_event_loop()
            config_path = self._okx_config_path()
            raw = await loop.run_in_executor(
                self.executor,
                lambda: _okx_module.okx_fetch_balance(config_path=config_path),
            )
            if not raw:
                return {}
            return {
                "total_eq": float(raw.get("total_eq", 0)),
                "avail_eq": float(raw.get("avail_eq", 0)),
                "equity_usdt": float(raw.get("equity_usdt", raw.get("total_eq", 0))),
                "cash_balance": float(raw.get("cash_balance", 0)),
                "available_margin": float(
                    raw.get("available_margin", raw.get("avail_eq", 0))
                ),
                "used_margin": float(raw.get("used_margin", 0)),
                "upl": float(raw.get("upl", 0)),
            }
        if not exchange:
            raise ValueError(f"交易所 {exchange_type.value} 未连接")
        try:
            balance = await exchange.fetch_balance()
            return {currency: info.total for currency, info in balance.items() if info.total > 0}
        except Exception as e:
            logger.error(f"获取 {exchange_type.value} 余额失败: {e}")
            raise
    
    async def get_positions(self, exchange_type: ModelExchangeType) -> List[Dict[str, Any]]:
        """
        获取交易所持仓（OKX 本地模块委托 okx_fetch_positions）
        """
        exchange = self.exchanges.get(exchange_type)
        if exchange_type == ModelExchangeType.OKX and exchange is _OKX_NATIVE_SENTINEL:
            loop = asyncio.get_event_loop()
            config_path = self._okx_config_path()
            positions, _ = await loop.run_in_executor(
                self.executor,
                lambda: _okx_module.okx_fetch_positions(config_path=config_path),
            )
            return [
                {
                    "symbol": p.get("inst_id", ""),
                    "side": p.get("pos_side", "long"),
                    "amount": abs(float(p.get("pos", 0))),
                    "entry_price": float(p.get("avg_px", 0)),
                    "mark_price": float(p.get("mark_px", 0)),
                    "unrealized_pnl": float(p.get("upl", 0)),
                    "leverage": 1,
                }
                for p in (positions or [])
            ]
        if not exchange:
            raise ValueError(f"交易所 {exchange_type.value} 未连接")
        try:
            positions = await exchange.fetch_positions()
            return [
                {
                    "symbol": pos.symbol,
                    "side": pos.side.value,
                    "amount": pos.amount,
                    "entry_price": pos.entry_price,
                    "mark_price": pos.mark_price,
                    "unrealized_pnl": pos.unrealized_pnl,
                    "leverage": pos.leverage
                }
                for pos in positions
            ]
        except Exception as e:
            logger.error(f"获取 {exchange_type.value} 持仓失败: {e}")
            raise
    
    async def get_ticker(self, exchange_type: ModelExchangeType, symbol: str) -> Dict[str, Any]:
        """
        获取交易所行情（OKX 支持 inst_id 或 ccxt 符号，本地模块仅返回 last）
        """
        exchange = self.exchanges.get(exchange_type)
        if exchange_type == ModelExchangeType.OKX and exchange is _OKX_NATIVE_SENTINEL:
            inst_id = symbol
            if ":" in symbol:
                base_quote = symbol.split(":")[0]
                quote = symbol.split(":")[1] if ":" in symbol else "USDT"
                inst_id = f"{base_quote.replace('/', '-')}-{quote}-SWAP"
            loop = asyncio.get_event_loop()
            last = await loop.run_in_executor(
                self.executor,
                lambda: _okx_module.okx_fetch_ticker(inst_id),
            )
            return {
                "symbol": symbol,
                "last": last,
                "bid": last,
                "ask": last,
                "high": None,
                "low": None,
                "volume": None,
                "timestamp": datetime.utcnow().isoformat() + "Z",
            }
        if not exchange:
            raise ValueError(f"交易所 {exchange_type.value} 未连接")
        try:
            ticker = await exchange.fetch_ticker(symbol)
            return {
                "symbol": ticker.symbol,
                "last": ticker.last,
                "bid": ticker.bid,
                "ask": ticker.ask,
                "high": ticker.high,
                "low": ticker.low,
                "volume": ticker.volume,
                "timestamp": ticker.timestamp.isoformat()
            }
        except Exception as e:
            logger.error(f"获取 {exchange_type.value} 行情失败: {e}")
            raise
    
    def get_exchange_status(self) -> Dict[ModelExchangeType, bool]:
        """
        获取所有交易所连接状态（OKX 本地占位视为已连接）
        """
        return {
            exchange_type: (exchange is not None) or (exchange_type == ModelExchangeType.OKX)
            for exchange_type, exchange in self.exchanges.items()
        }
    
    def get_enabled_exchanges(self) -> List[ModelExchangeType]:
        """
        获取启用的交易所列表
        
        Returns:
            List[ModelExchangeType]: 启用的交易所
        """
        return list(self.exchanges.keys())
    
    async def close_all_connections(self) -> None:
        """关闭所有交易所连接（OKX 本地占位无需关闭）"""
        for exchange_type, exchange in self.exchanges.items():
            if exchange is _OKX_NATIVE_SENTINEL:
                logger.debug("%s 使用本地模块，无需关闭连接", exchange_type.value)
                continue
            try:
                if exchange and hasattr(exchange, 'close'):
                    await exchange.close()
                logger.debug("%s 交易所连接已关闭", exchange_type.value)
            except Exception as e:
                logger.error(f"关闭 {exchange_type.value} 交易所连接失败: {e}")
        
        self.exchanges.clear()
        self.exchange_configs.clear()
        
        # 关闭线程池
        self.executor.shutdown(wait=True)
        
        logger.debug("所有交易所连接已关闭")
    
    def __del__(self):
        """析构函数"""
        try:
            if hasattr(self, 'executor'):
                self.executor.shutdown(wait=False)
        except:
            pass


# 全局交易所管理器实例
exchange_manager = ExchangeManager()


def get_exchange_manager() -> ExchangeManager:
    """获取交易所管理器实例"""
    return exchange_manager


async def execute_orders(order_requests: List[OrderRequest]) -> List[OrderResult]:
    """执行订单列表的便捷函数"""
    return await exchange_manager.execute_orders_concurrent(order_requests)


async def execute_single_order(order_request: OrderRequest) -> OrderResult:
    """执行单个订单的便捷函数"""
    return await exchange_manager.execute_order(order_request)


if __name__ == "__main__":
    # 测试交易所管理器
    import asyncio
    
    async def test_exchange_manager():
        manager = ExchangeManager()
        
        # 测试连接状态
        status = manager.get_exchange_status()
        print("交易所连接状态:")
        for exchange, connected in status.items():
            print(f"  {exchange.value}: {'已连接' if connected else '未连接'}")
        
        # 测试获取余额（如果有连接的交易所）
        enabled_exchanges = manager.get_enabled_exchanges()
        if enabled_exchanges:
            exchange_type = enabled_exchanges[0]
            try:
                balance = await manager.get_balance(exchange_type)
                print(f"\n{exchange_type.value} 余额:")
                for currency, amount in balance.items():
                    print(f"  {currency}: {amount}")
            except Exception as e:
                print(f"获取余额失败: {e}")
        
        # 关闭连接
        await manager.close_all_connections()
    
    asyncio.run(test_exchange_manager())
