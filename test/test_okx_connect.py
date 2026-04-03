#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""测试 OKX 连接：使用 server/exchange/okx.py 对三份 Accounts 配置做余额、持仓验证。"""
import sys
from pathlib import Path

# 保证可导入 server.exchange.okx
ROOT = Path(__file__).resolve().parent.parent
if str(ROOT / "server") not in sys.path:
    sys.path.insert(0, str(ROOT / "server"))

from exchange.okx import load_okx_config, okx_fetch_balance, okx_fetch_positions, okx_request

BOTCONFIG = ROOT / "server" / "Accounts"
CONFIGS = [
    "OKX_Alang_Sandbox.json",
    "OKX_Hztech_Devops.json",
    "OKX_Dong_Live.json",
]


def main():
    print("OKX 连接测试（余额与持仓）\n")
    all_ok = True
    for name in CONFIGS:
        path = BOTCONFIG / name
        if not path.exists():
            print(f"  [{name}] 跳过：文件不存在")
            continue
        cfg = load_okx_config(path)
        if not cfg:
            print(f"  [{name}] 失败：配置解析失败")
            all_ok = False
            continue
        if not (cfg.get("key") and cfg.get("secret")):
            print(f"  [{name}] 失败：缺少 key 或 secret")
            all_ok = False
            continue
        label = cfg.get("name") or path.stem
        sandbox = "沙盒" if cfg.get("sandbox") else "实盘"
        result = okx_fetch_balance(path)
        if result is None:
            data, err = okx_request("GET", "/api/v5/account/balance", config_path=path)
            reason = err or (data.get("msg") if isinstance(data, dict) else None) or "未知"
            print(f"  [{name}] {label} ({sandbox}) -> 连接失败: {reason}")
            all_ok = False
        else:
            total = result.get("total_eq", 0)
            avail = result.get("avail_eq", 0)
            print(f"  [{name}] {label} ({sandbox}) -> 成功 | total_eq={total:.2f} avail_eq={avail:.2f}")
        # 当前持仓
        positions, pos_err = okx_fetch_positions(path)
        if pos_err:
            print(f"      持仓: 获取失败 - {pos_err}")
        elif not positions:
            print(f"      持仓: 0 个")
        else:
            print(f"      持仓: {len(positions)} 个")
            for p in positions:
                inst = p.get("inst_id", "")
                side = p.get("pos_side", "")
                pos = p.get("pos", 0)
                avg_px = p.get("avg_px", 0)
                upl = p.get("upl", 0)
                print(f"        - {inst} {side} {pos:+.2f} 均价={avg_px:.4f} 未实现盈亏={upl:.2f}")
    print()
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
