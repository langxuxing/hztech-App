# -*- coding: utf-8 -*-
"""
从 Account_List.json 管理 OKX 账户：列表、密钥路径、余额快照（入库）、
行情/持仓/委托（仅实时查询，不入库）。

与 server/main.py 集成：/api/account-profit、/api/tradingbots、按 account_id 的
positions / profit-history / ticker / pending-orders 等通过本模块解析密钥与账户元数据。

定时任务由 main 每 5 分钟调用 refresh_all_snapshots / refresh_all_positions_history，写入 SQLite：
- 现金余额（avail_eq）、权益（total_eq）→ account_snapshots
- OKX 历史仓位（/api/v5/account/positions-history）→ account_positions_history
- 各账户初始资金（来自 JSON Initial_capital）、每月月初权益（自然月首次快照）
"""
from __future__ import annotations

import importlib.util
import logging
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ACCOUNTS_DIR = Path(__file__).resolve().parent

_test_account_key_mod: Any = None


def _test_account_key():
    global _test_account_key_mod
    if _test_account_key_mod is None:
        p = ACCOUNTS_DIR / "test_account_key.py"
        spec = importlib.util.spec_from_file_location("test_account_key", p)
        if spec is None or spec.loader is None:
            raise RuntimeError("无法加载 test_account_key")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _test_account_key_mod = mod
    return _test_account_key_mod


def load_account_list() -> list[dict]:
    return _test_account_key().load_account_list()


def resolve_key_file_path(account_key_file: str) -> Path:
    return _test_account_key().resolve_key_file_path(account_key_file)


def _parse_enabled(value: object) -> bool:
    return _test_account_key()._parse_enabled(value)


def iter_okx_accounts(*, enabled_only: bool = True) -> list[dict]:
    """OKX 账户行（来自 Account_List），含 account_id、account_name、symbol、密钥文件名等。"""
    rows: list[dict] = []
    for row in load_account_list():
        if (row.get("exchange_account") or "").strip().upper() != "OKX":
            continue
        if enabled_only and not _parse_enabled(row.get("enbaled")):
            continue
        aid = str(row.get("account_id") or "").strip()
        if not aid:
            continue
        key_name = (row.get("account_key_file") or "").strip()
        if not key_name:
            continue
        rows.append(row)
    return rows


def resolve_okx_config_path(account_id: str) -> Path | None:
    """解析 OKX JSON 配置文件路径；不存在则返回 None。"""
    want = (account_id or "").strip()
    if not want:
        return None
    for row in load_account_list():
        if str(row.get("account_id") or "").strip() != want:
            continue
        if (row.get("exchange_account") or "").strip().upper() != "OKX":
            return None
        key_name = (row.get("account_key_file") or "").strip()
        if not key_name:
            return None
        path = resolve_key_file_path(key_name)
        return path if path.is_file() else None
    return None


def resolve_okx_key_write_path(account_id: str) -> Path | None:
    """客户上传密钥时写入路径（与 Account_List 中 account_key_file 一致；文件可尚不存在）。"""
    want = (account_id or "").strip()
    if not want:
        return None
    for row in load_account_list():
        if str(row.get("account_id") or "").strip() != want:
            continue
        if (row.get("exchange_account") or "").strip().upper() != "OKX":
            return None
        key_name = (row.get("account_key_file") or "").strip()
        if not key_name:
            return None
        return resolve_key_file_path(key_name)
    return None


def _initial_capital(row: dict) -> float:
    v = row.get("Initial_capital")
    if v is None:
        v = row.get("initial_capital")
    try:
        return float(v) if v is not None else 0.0
    except (TypeError, ValueError):
        return 0.0


def account_basic_dict(row: dict) -> dict[str, Any]:
    """账户静态信息（不含密钥）。"""
    aid = str(row.get("account_id") or "").strip()
    return {
        "account_id": aid,
        "account_name": (row.get("account_name") or aid).strip(),
        "exchange_account": (row.get("exchange_account") or "OKX").strip(),
        "symbol": (row.get("symbol") or "").strip(),
        "initial_capital": _initial_capital(row),
        "trading_strategy": (row.get("trading_strategy") or "").strip(),
        "account_key_file": (row.get("account_key_file") or "").strip(),
        "script_file": (row.get("script_file") or "").strip(),
        "enabled": _parse_enabled(row.get("enbaled")),
    }


def list_account_basics(*, enabled_only: bool = True) -> list[dict[str, Any]]:
    return [account_basic_dict(r) for r in iter_okx_accounts(enabled_only=enabled_only)]


def sync_account_meta_from_json(db_module: Any) -> None:
    """将 Account_List 中的 Initial_capital 同步到 account_meta。"""
    for row in iter_okx_accounts(enabled_only=False):
        aid = str(row.get("account_id") or "").strip()
        if not aid:
            continue
        db_module.account_meta_upsert(aid, _initial_capital(row))


def sync_account_meta_after_account_list_write(db_module: Any) -> None:
    """管理员写入 Account_List.json 后调用：按 JSON 同步各账户 initial_capital，并删除已从列表移除的 meta 行。"""
    sync_account_meta_from_json(db_module)
    valid_ids = {
        str(r.get("account_id") or "").strip()
        for r in load_account_list()
        if str(r.get("account_id") or "").strip()
    }
    db_module.account_meta_prune_except(valid_ids)


def refresh_all_balance_snapshots(db_module: Any, logger: logging.Logger | None = None) -> None:
    """
    拉取各 OKX 账户余额并写入 account_snapshots；维护当月月初权益记录。
    应在定时器内调用（建议每 5 分钟）。
    """
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    sync_account_meta_from_json(db_module)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    ym = datetime.now(timezone.utc).strftime("%Y-%m")

    for row in iter_okx_accounts(enabled_only=True):
        aid = str(row.get("account_id") or "").strip()
        path = resolve_okx_config_path(aid)
        meta = db_module.account_meta_get(aid)
        initial = float(meta["initial_capital"]) if meta else _initial_capital(row)

        if not path:
            log.debug("account_snapshot_skip: %s 无密钥文件", aid)
            continue

        live = okx_mod.okx_fetch_balance(config_path=path)
        if not live:
            db_module.log_insert(
                "WARN",
                "account_snapshot_skip",
                source="account_mgr",
                extra={"account_id": aid, "reason": "balance_fetch_failed"},
            )
            continue

        total_eq = float(live.get("equity_usdt") or live.get("total_eq") or 0.0)
        cash = float(live.get("cash_balance") or live.get("avail_eq") or 0.0)
        upl = float(live.get("upl") or 0.0)
        profit_amount = total_eq - initial
        profit_percent = (profit_amount / initial * 100.0) if initial else 0.0

        db_module.account_snapshot_insert(
            account_id=aid,
            snapshot_at=ts,
            cash_balance=cash,
            equity_usdt=total_eq,
            initial_capital=initial,
            profit_amount=profit_amount,
            profit_percent=profit_percent,
        )

        if db_module.account_month_open_get(aid, ym) is None:
            db_module.account_month_open_insert_if_absent(
                aid, ym, total_eq, ts
            )

        log.debug(
            "account_snapshot_ok: %s equity=%s cash=%s",
            aid,
            total_eq,
            cash,
        )

def _fetch_and_save_tradingbot_snapshots() -> None:
        """读取 tradingbots.json 中的 OKX 机器人余额，写入 bot_profit_snapshots 表。"""
        bots = _load_tradingbots_config()
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        for b in bots:
            bot_id = (b.get("tradingbot_id") or "").strip()
            if not bot_id:
                continue
            config_path = _bot_okx_config_path(bot_id)
            if not config_path:
                continue
            try:
                balance = _okx.okx_fetch_balance(config_path=config_path)
                if balance is None:
                    continue
                total_eq = float(balance.get("equity_usdt") or balance.get("total_eq") or 0.0)
                prev = _db.bot_profit_latest_by_bot(bot_id)
                initial = float(prev["initial_balance"]) if prev else total_eq
                if prev is None and total_eq > 0:
                    initial = total_eq
                profit_amount = total_eq - initial
                profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
                _db.bot_profit_insert(
                    bot_id=bot_id,
                    snapshot_at=ts,
                    initial_balance=initial,
                    current_balance=total_eq,
                    equity_usdt=total_eq,
                    profit_amount=profit_amount,
                    profit_percent=profit_percent,
                )
            except Exception as e:
                _db.log_insert(
                    "WARN",
                    "account_snapshot_failed",
                    source="timer",
                    extra={"bot_id": bot_id, "error": str(e)},
                )

def refresh_all_positions_history(
    db_module: Any, logger: logging.Logger | None = None
) -> None:
    """
    拉取各 OKX 账户 positions-history（默认 SWAP，多页）并写入 account_positions_history。
    与 refresh_all_snapshots 同周期调用即可（建议每 5 分钟）。
    """
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    for row in iter_okx_accounts(enabled_only=True):

        aid = str(row.get("account_id") or "").strip()
        path = resolve_okx_config_path(aid)
        if not path:
            log.debug("positions_history_skip: %s 无密钥文件", aid)
            continue

        hist, err = okx_mod.okx_fetch_positions_history(config_path=path)
        if err:
            db_module.log_insert(
                "WARN",
                "positions_history_fetch_failed",
                source="account_mgr",
                extra={"account_id": aid, "error": err},
            )
            continue
        if not hist:
            continue
        n = db_module.account_positions_history_insert_batch(aid, hist, ts)
        log.debug(
            "positions_history_ok: %s api_rows=%d inserted=%d",
            aid,
            len(hist),
            n,
        )


def refresh_positions_history_one(
    db_module: Any, account_id: str, logger: logging.Logger | None = None
) -> tuple[bool, str]:
    """拉取单个 OKX 账户的 positions-history 并写入 account_positions_history。"""
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    aid = str(account_id or "").strip()
    if not aid:
        return False, "缺少 account_id"
    path = resolve_okx_config_path(aid)
    if not path:
        return False, "未找到密钥配置"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    hist, err = okx_mod.okx_fetch_positions_history(config_path=path)
    if err:
        db_module.log_insert(
            "WARN",
            "positions_history_fetch_failed",
            source="account_mgr",
            extra={"account_id": aid, "error": err},
        )
        return False, err
    if not hist:
        return True, "无新历史仓位数据"
    n = db_module.account_positions_history_insert_batch(aid, hist, ts)
    log.info("positions_history_one_ok: %s api_rows=%d inserted=%d", aid, len(hist), n)
    return True, f"已写入 {n} 条新记录"


# --- 实时查询（不入库） ---


def fetch_balance_live(account_id: str) -> dict | None:
    import exchange.okx as okx_mod

    path = resolve_okx_config_path(account_id)
    if not path:
        return None
    return okx_mod.okx_fetch_balance(config_path=path)


def fetch_positions_live(account_id: str) -> tuple[list[dict], str | None]:
    import exchange.okx as okx_mod

    path = resolve_okx_config_path(account_id)
    if not path:
        return ([], "账户未配置或密钥文件不存在")
    return okx_mod.okx_fetch_positions(config_path=path)


def fetch_ticker_for_inst(inst_id: str) -> float | None:
    import exchange.okx as okx_mod

    return okx_mod.okx_fetch_ticker(inst_id)


def fetch_pending_orders_live(account_id: str) -> tuple[list[dict], str | None]:
    import exchange.okx as okx_mod

    path = resolve_okx_config_path(account_id)
    if not path:
        return ([], "账户未配置或密钥文件不存在")
    return okx_mod.okx_fetch_pending_orders(config_path=path)


def collect_accounts_profit_for_api(db_module: Any) -> list[dict]:
    """
    组装 /api/account-profit 的 accounts 数组（与现有 AccountProfit 字段兼容）。
    bot_id 使用 account_id，便于客户端沿用同一套下拉与持仓 API。
    多账户时对 OKX 余额请求并行执行，避免串行累加超过客户端 HTTP 超时。
    """
    import exchange.okx as okx_mod

    rows = iter_okx_accounts(enabled_only=True)
    prep: list[tuple[str, str, Any, Any, float, float | None]] = []
    for row in rows:
        aid = str(row.get("account_id") or "").strip()
        ex_name = (row.get("exchange_account") or "OKX").strip()
        path = resolve_okx_config_path(aid)
        snap = db_module.account_snapshot_latest_by_account(aid)
        meta_row = db_module.account_meta_get(aid)
        initial = float(meta_row["initial_capital"]) if meta_row else _initial_capital(row)
        ym = datetime.now(timezone.utc).strftime("%Y-%m")
        month_row = db_module.account_month_open_get(aid, ym)
        month_open = float(month_row["open_equity"]) if month_row else None
        prep.append((aid, ex_name, path, snap, initial, month_open))

    live_by_aid: dict[str, dict | None] = {}
    fetch_jobs = [(p[0], p[2]) for p in prep if p[2] is not None]
    if fetch_jobs:

        def _fetch_balance(job: tuple[str, Any]) -> tuple[str, dict | None]:
            account_id, cfg_path = job
            return account_id, okx_mod.okx_fetch_balance(config_path=cfg_path)

        workers = min(16, max(1, len(fetch_jobs)))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for aid, live in pool.map(_fetch_balance, fetch_jobs):
                live_by_aid[aid] = live

    out: list[dict] = []
    for aid, ex_name, path, snap, initial, month_open in prep:
        live = live_by_aid.get(aid) if path else None
        if live:
            total_eq = float(live.get("equity_usdt") or live.get("total_eq") or 0.0)
            avail_eq = float(live.get("cash_balance") or live.get("avail_eq") or 0.0)
            upl = float(live.get("upl") or 0.0)
            profit_amount = total_eq - initial
            profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
            out.append(
                {
                    "bot_id": aid,
                    "account_id": aid,
                    "exchange_account": ex_name,
                    "initial_balance": initial,
                    "current_balance": total_eq,
                    "profit_amount": profit_amount,
                    "profit_percent": profit_percent,
                    "floating_profit": upl,
                    "equity_usdt": total_eq,
                    "balance_usdt": avail_eq,
                    "snapshot_time": snap["snapshot_at"] if snap else None,
                    "month_open_equity": month_open,
                }
            )
        elif snap:
            eq = float(snap["equity_usdt"])
            cash = float(snap["cash_balance"])
            out.append(
                {
                    "bot_id": aid,
                    "account_id": aid,
                    "exchange_account": ex_name,
                    "initial_balance": float(snap["initial_capital"]),
                    "current_balance": eq,
                    "profit_amount": float(snap["profit_amount"]),
                    "profit_percent": float(snap["profit_percent"]),
                    "floating_profit": 0.0,
                    "equity_usdt": eq,
                    "balance_usdt": cash,
                    "snapshot_time": snap["snapshot_at"],
                    "month_open_equity": month_open,
                }
            )
        else:
            out.append(
                {
                    "bot_id": aid,
                    "account_id": aid,
                    "exchange_account": ex_name,
                    "initial_balance": initial,
                    "current_balance": 0,
                    "profit_amount": 0,
                    "profit_percent": 0,
                    "floating_profit": 0,
                    "equity_usdt": 0,
                    "balance_usdt": 0,
                    "snapshot_time": None,
                    "month_open_equity": month_open,
                }
            )
    return out


def collect_tradingbots_style_list(strategy_status_fn: Any) -> list[dict]:
    """
    供 /api/tradingbots 使用：与 UnifiedTradingBot 兼容的列表，数据来自 Account_List。
    tradingbot_id = account_id；策略运行状态按 tradingbot_id 匹配 strategy_status。
    """
    st = strategy_status_fn()
    bots_status = (st or {}).get("bots") or {}
    out: list[dict] = []
    for basic in list_account_basics(enabled_only=True):
        aid = basic["account_id"]
        bot_st = bots_status.get(aid) or {}
        is_running = bool(bot_st.get("running", False))
        sf = (basic.get("script_file") or "").strip()
        script_path = (ACCOUNTS_DIR / sf) if sf else None
        can_ctrl = bool(sf and script_path and script_path.is_file())
        out.append(
            {
                "tradingbot_id": aid,
                "tradingbot_name": basic.get("account_name") or aid,
                "exchange_account": basic.get("exchange_account"),
                "symbol": basic.get("symbol"),
                "strategy_name": basic.get("trading_strategy") or "",
                "status": "running" if is_running else "stopped",
                "is_running": is_running,
                "can_control": can_ctrl,
                "enabled": basic.get("enabled", True),
            }
        )
    return out
