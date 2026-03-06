#!/usr/bin/env python3
"""每分钟查询 OKX BTC 永续合约价格并打印。"""

import json
import time
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

OKX_TICKER_URL = "https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT-SWAP"
INTERVAL_SEC = 60


def fetch_btc_price() -> str | None:
    """请求 OKX 获取 BTC-USDT 永续最新价，成功返回价格字符串，失败返回 None。"""
    try:
        req = Request(OKX_TICKER_URL, headers={"User-Agent": "hztech-simpleserver/1.0"})
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
    print("OKX BTC-USDT 永续合约价格轮询（每 1 分钟）")
    print("Ctrl+C 退出\n")
    while True:
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        price = fetch_btc_price()
        if price is not None:
            print(f"[{ts}] BTC-USDT-SWAP 最新价: {price} USDT")
        time.sleep(INTERVAL_SEC)


if __name__ == "__main__":
    main()
