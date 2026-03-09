#!/usr/bin/env python3
"""lhg bot：每分钟查询 OKX BTC 永续合约价格并打印。启动/退出时写入数据库 strategy_events；支持 SIGTERM 优雅退出。"""

import json
import signal
import sys
import time
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# 与 app 共用同一 DB（server/sqlite/tradingbots.db），需在 server 目录或项目根下以 python server/simpleserver-lhg.py 运行
import db as _db

OKX_TICKER_URL = "https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT-SWAP"
INTERVAL_SEC = 60
BOT_ID = "simpleserver-lhg"


def _on_shutdown(*_args):
    """收到 SIGTERM/SIGINT 时写库并退出。"""
    try:
        _db.strategy_event_insert(BOT_ID, "stop", "auto", None)
    except Exception:
        pass
    sys.exit(0)


def fetch_btc_price() -> str | None:
    """请求 OKX 获取 BTC-USDT 永续最新价，成功返回价格字符串，失败返回 None。"""
    try:
        req = Request(OKX_TICKER_URL, headers={"User-Agent": "hztech-simpleserver-lhg/1.0"})
        with urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
    except (URLError, HTTPError, json.JSONDecodeError, KeyError) as e:
        print(f"[错误] 请求失败: {e}")
        return None
    if data.get("code") != "0":
        print(f"[错误] API 返回: code={data.get('code')} msg={data.get('msg')}")
        return None
    items = data.get("data") or []
    if not items:
        print("[错误] API 返回 data 为空")
        return None
    return items[0].get("last")


def main():
    signal.signal(signal.SIGTERM, _on_shutdown)
    signal.signal(signal.SIGINT, _on_shutdown)

    _db.init_db()
    try:
        _db.strategy_event_insert(BOT_ID, "start", "auto", None)
    except Exception:
        pass

    print("OKX BTC-USDT 永续合约价格轮询（每 1 分钟）")
    print("Ctrl+C 或 SIGTERM 退出\n")
    while True:
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        price = fetch_btc_price()
        if price is not None:
            print(f"[{ts}] BTC-USDT-SWAP 最新价: {price} USDT")
        time.sleep(INTERVAL_SEC)


if __name__ == "__main__":
    main()
