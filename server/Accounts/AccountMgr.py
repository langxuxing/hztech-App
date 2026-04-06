# -*- coding: utf-8 -*-
"""
从 Account_List.json 管理 OKX 账户：列表、密钥路径、余额快照（入库）、
行情/持仓/委托（仅实时查询，不入库）。

与 server/main.py 集成：/api/account-profit、/api/tradingbots、按 account_id 的
positions / profit-history / ticker / pending-orders 等通过本模块解析密钥与账户元数据。

定时任务由 main 每 5 分钟调用，写入 SQLite：
- 现金余额（avail_eq）、权益（total_eq）→ account_snapshots（Account_List）；tradingbots.json → bot_profit_snapshots
- 管理员「余额同步」可对缺日调用 OKX bills-archive（USDT bal）补全 account_snapshots；权益按最近快照 equity/cash 比例估算
- 多时点快照经 strategy_efficiency.daily_cash_delta_by_utc_day 汇总为 UTC 自然日现金增量，再算现金收益率%、策略能效
- OKX 历史仓位 → account_positions_history（SWAP+FUTURES 合并去重，深分页）；
  再汇总写入 account_daily_close_performance（按 UTC 日平仓净盈亏、权益口径日收益率%、对标合约 TR 的策略能效）
- 各账户初始资金（Initial_capital）、当月 account_month_open
"""
from __future__ import annotations

import importlib.util
import logging
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

ACCOUNTS_DIR = Path(__file__).resolve().parent

# 定时任务 DEBUG 日志：账号列宽（超长截断后左对齐）
_LOG_ACCOUNT_COL_WIDTH = 20


def _fmt_log_account_id(account_id: str, width: int = _LOG_ACCOUNT_COL_WIDTH) -> str:
    s = str(account_id or "").strip()
    if len(s) > width:
        s = s[:width]
    return s.ljust(width)


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


def okx_sandbox_from_key_file(account_key_file: str) -> bool:
    """OKX 密钥 JSON 中 api.sandbox 为 true 时返回 True；文件缺失或无法解析时为 False。"""
    key_name = (account_key_file or "").strip()
    if not key_name:
        return False
    path = resolve_key_file_path(key_name)
    cfg = _test_account_key().load_config(path)
    if not cfg:
        return False
    return bool(cfg.get("sandbox"))


def _parse_enabled(value: object) -> bool:
    return _test_account_key()._parse_enabled(value)


def _account_row_enabled(row: dict) -> bool:
    """与 test_account_key.account_row_is_enabled 一致：优先 enbaled，其次 enabled。"""
    return _test_account_key().account_row_is_enabled(row)


def okx_account_disabled_exchange_reason(account_id: str) -> str | None:
    """
    Account_List 中该 account_id 若为 OKX 且 enbaled=false，返回说明文案；
    各定时任务与实时接口据此拒绝访问 OKX（测连、持仓、委托、余额等）。
    未出现在列表或非 OKX 行则返回 None。
    """
    aid = str(account_id or "").strip()
    if not aid:
        return None
    for row in load_account_list():
        if str(row.get("account_id") or "").strip() != aid:
            continue
        if (row.get("exchange_account") or "").strip().upper() != "OKX":
            return None
        if not _account_row_enabled(row):
            return "账户已在 Account_List 中禁用（enbaled/enabled 为 false），不进行 OKX 请求"
        return None
    return None


def iter_okx_accounts(*, enabled_only: bool = True) -> list[dict]:
    """OKX 账户行（来自 Account_List），含 account_id、account_name、symbol、密钥文件名等。"""
    rows: list[dict] = []
    for row in load_account_list():
        if (row.get("exchange_account") or "").strip().upper() != "OKX":
            continue
        if enabled_only and not _account_row_enabled(row):
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
        "enabled": _account_row_enabled(row),
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
            log.debug(
                "账号快照跳过: %s 无密钥文件",
                _fmt_log_account_id(aid),
            )
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
                aid, ym, total_eq, ts, open_cash=cash
            )

        log.debug(
            "账户快照: %s \t权益=%d \t现金=%d",
            _fmt_log_account_id(aid),
            int(round(total_eq)),
            int(round(cash)),
        )


def backfill_account_snapshots_from_okx_bills(
    db_module: Any,
    account_id: str,
    logger: logging.Logger | None = None,
    *,
    days: int = 40,
) -> tuple[int, str]:
    """用 OKX ``/api/v5/account/bills-archive`` 的 USDT ``bal`` 补全近期缺日的 ``account_snapshots``（UTC 自然日）。

    仅插入「该日尚无任何快照」的日期；现金取账单余额，权益按补全前最近一条快照的 equity/cash 比例估算
    （持仓时与 OKX totalEq 可能略有偏差）。
    """
    import exchange.okx as okx_mod

    log = logger or logging.getLogger(__name__)
    aid = str(account_id or "").strip()
    if not aid:
        return 0, "缺少 account_id"
    br = okx_account_disabled_exchange_reason(aid)
    if br:
        return 0, br
    path = resolve_okx_config_path(aid)
    if not path or not path.is_file():
        return 0, "无密钥"

    nd = max(7, min(92, int(days)))
    now = datetime.now(timezone.utc)
    end_d = now.date()
    start_d = end_d - timedelta(days=nd - 1)
    begin_ms = int(
        datetime(
            start_d.year, start_d.month, start_d.day, tzinfo=timezone.utc
        ).timestamp()
        * 1000
    )
    end_ms = int(now.timestamp() * 1000)

    rows, err = okx_mod.okx_fetch_account_bills_archive_usdt(
        path, begin_ms=begin_ms, end_ms=end_ms
    )
    if err and not rows:
        return 0, err or "bills-archive 无数据"
    if err:
        log.warning("bills-archive: %s %s", _fmt_log_account_id(aid), err)

    by_day: dict = {}
    for r in rows:
        if (r.get("ccy") or "").upper() != "USDT":
            continue
        try:
            ts_i = int(float(r.get("ts") or 0))
            bal_f = float(r.get("bal") or 0)
        except (TypeError, ValueError):
            continue
        if ts_i <= 0:
            continue
        bd = datetime.fromtimestamp(ts_i / 1000.0, tz=timezone.utc).date()
        prev = by_day.get(bd)
        if prev is None or ts_i >= prev[0]:
            by_day[bd] = (ts_i, bal_f)

    filled_bal: dict = {}
    carry = None
    walk = start_d
    while walk <= end_d:
        if walk in by_day:
            carry = by_day[walk][1]
        if carry is not None:
            filled_bal[walk] = carry
        walk = walk + timedelta(days=1)

    if not filled_bal:
        return 0, "账单区间内无 USDT 余额记录"

    meta = db_module.account_meta_get(aid)
    initial = float(meta["initial_capital"]) if meta else 0.0
    if initial <= 0:
        for row in iter_okx_accounts(enabled_only=False):
            if str(row.get("account_id") or "").strip() == aid:
                initial = _initial_capital(row)
                break

    inserted = 0
    cur_d = start_d
    while cur_d <= end_d:
        day_s = cur_d.isoformat()
        if db_module.account_snapshot_exists_on_utc_date(aid, day_s):
            cur_d = cur_d + timedelta(days=1)
            continue
        if cur_d not in filled_bal:
            cur_d = cur_d + timedelta(days=1)
            continue
        cash_b = float(filled_bal[cur_d])
        cutoff = f"{day_s}T23:59:58.000000Z"
        prev = db_module.account_snapshot_last_before_instant(aid, cutoff)
        cash_prev = float(prev["cash_balance"]) if prev else 0.0
        eq_prev = float(prev["equity_usdt"]) if prev else 0.0
        ratio = (eq_prev / cash_prev) if cash_prev > 1e-12 else 1.0
        equity = cash_b * ratio
        profit_amount = equity - initial
        profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
        snap_at = f"{day_s}T23:59:59.000000Z"
        db_module.account_snapshot_insert(
            account_id=aid,
            snapshot_at=snap_at,
            cash_balance=cash_b,
            equity_usdt=equity,
            initial_capital=initial,
            profit_amount=profit_amount,
            profit_percent=profit_percent,
        )
        inserted += 1
        cur_d = cur_d + timedelta(days=1)

    return inserted, f"插入 {inserted} 条缺日快照"


def refresh_balance_snapshot_one(
    db_module: Any, account_id: str, logger: logging.Logger | None = None
) -> tuple[bool, str]:
    """
    从 OKX 拉取单账户余额，写入 account_snapshots（现金 availEq、权益），并维护当月 account_month_open。
    供管理员手动同步；策略效能日现金增量依赖此表多时点快照。
    """
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    aid = str(account_id or "").strip()
    if not aid:
        return False, "缺少 account_id"
    br = okx_account_disabled_exchange_reason(aid)
    if br:
        return False, br
    path = resolve_okx_config_path(aid)
    if not path or not path.is_file():
        return False, "未找到密钥配置"

    meta = db_module.account_meta_get(aid)
    initial = float(meta["initial_capital"]) if meta else 0.0
    if initial <= 0:
        for row in iter_okx_accounts(enabled_only=False):
            if str(row.get("account_id") or "").strip() == aid:
                initial = _initial_capital(row)
                break

    sync_account_meta_from_json(db_module)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    ym = datetime.now(timezone.utc).strftime("%Y-%m")

    live = okx_mod.okx_fetch_balance(config_path=path)
    if not live:
        return False, "OKX 余额拉取失败"

    total_eq = float(live.get("equity_usdt") or live.get("total_eq") or 0.0)
    cash = float(live.get("cash_balance") or live.get("avail_eq") or 0.0)
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
            aid, ym, total_eq, ts, open_cash=cash
        )

    log.info(
        "balance_snapshot_one_ok: %s equity=%s cash=%s",
        _fmt_log_account_id(aid),
        int(round(total_eq)),
        int(round(cash)),
    )
    try:
        n_b, _bf = backfill_account_snapshots_from_okx_bills(
            db_module, aid, log, days=40
        )
    except Exception as e:
        log.warning(
            "balance_snapshot_bills_backfill_failed: %s %s",
            _fmt_log_account_id(aid),
            e,
        )
        n_b = 0
    if n_b > 0:
        return True, f"已写入 account_snapshots；OKX 账单已补全 {n_b} 个缺日"
    return True, "已写入 account_snapshots"


def _load_tradingbots_json_bots() -> list[dict]:
    """Accounts/tradingbots.json 中的 bot 列表（无文件则空列表）。"""
    import json

    path = ACCOUNTS_DIR / "tradingbots.json"
    if not path.is_file():
        return []
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def fetch_and_save_tradingbot_snapshots(
    db_module: Any, logger: logging.Logger | None = None
) -> None:
    """读取 tradingbots.json 中有 account_api_file 的 OKX 机器人余额，写入 bot_profit_snapshots。"""
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    bots = _load_tradingbots_json_bots()
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    for b in bots:
        bot_id = (b.get("tradingbot_id") or "").strip()
        if not bot_id:
            continue
        api_file = (b.get("account_api_file") or "").strip()
        if not api_file:
            continue
        config_path = ACCOUNTS_DIR / api_file
        if not config_path.is_file():
            continue
        try:
            balance = okx_mod.okx_fetch_balance(config_path=config_path)
            if balance is None:
                continue
            total_eq = float(balance.get("equity_usdt") or balance.get("total_eq") or 0.0)
            prev = db_module.bot_profit_latest_by_bot(bot_id)
            initial = float(prev["initial_balance"]) if prev else total_eq
            if prev is None and total_eq > 0:
                initial = total_eq
            profit_amount = total_eq - initial
            profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
            db_module.bot_profit_insert(
                bot_id=bot_id,
                snapshot_at=ts,
                initial_balance=initial,
                current_balance=total_eq,
                equity_usdt=total_eq,
                profit_amount=profit_amount,
                profit_percent=profit_percent,
            )
            log.debug(
                "bot_profit_snapshot: %s equity=%s",
                bot_id[:_LOG_ACCOUNT_COL_WIDTH].ljust(_LOG_ACCOUNT_COL_WIDTH),
                int(round(total_eq)),
            )
        except Exception as e:
            db_module.log_insert(
                "WARN",
                "bot_profit_snapshot_failed",
                source="account_mgr",
                extra={"bot_id": bot_id, "error": str(e)},
            )


def refresh_tradingbot_balance_snapshot_one(
    db_module: Any,
    bot_id: str,
    config_path: Path,
    logger: logging.Logger | None = None,
) -> tuple[bool, str]:
    """对仅存在于 tradingbots.json 的 bot：拉 OKX 余额写入 bot_profit_snapshots。"""
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    bid = (bot_id or "").strip()
    if not bid:
        return False, "缺少 bot_id"
    if not config_path.is_file():
        return False, "密钥文件不存在"

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    balance = okx_mod.okx_fetch_balance(config_path=config_path)
    if balance is None:
        return False, "OKX 余额拉取失败"
    total_eq = float(balance.get("equity_usdt") or balance.get("total_eq") or 0.0)
    prev = db_module.bot_profit_latest_by_bot(bid)
    initial = float(prev["initial_balance"]) if prev else total_eq
    if prev is None and total_eq > 0:
        initial = total_eq
    profit_amount = total_eq - initial
    profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
    db_module.bot_profit_insert(
        bot_id=bid,
        snapshot_at=ts,
        initial_balance=initial,
        current_balance=total_eq,
        equity_usdt=total_eq,
        profit_amount=profit_amount,
        profit_percent=profit_percent,
    )
    log.info("bot_profit_snapshot_one_ok: %s equity=%s", bid, int(round(total_eq)))
    return True, "已写入 bot_profit_snapshots"


def _account_benchmark_inst_map() -> dict[str, str]:
    """account_id → Account_List.symbol（作 market_daily_bars 对标 TR），空则用库表重建时的默认值。"""
    return {
        str(b["account_id"] or "").strip(): (b.get("symbol") or "").strip()
        for b in list_account_basics(enabled_only=False)
        if str(b.get("account_id") or "").strip()
    }


def refresh_all_positions_history(
    db_module: Any, logger: logging.Logger | None = None
) -> None:
    """
    拉取 Account_List 中已启用（enbaled=true）OKX 账户的 positions-history：
    SWAP + FUTURES 合并去重、深分页写入 account_positions_history；
    最后按账户重算 account_daily_close_performance。
    与 refresh_all_snapshots 同周期调用即可（建议每 5 分钟）。
    """
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    for row in iter_okx_accounts(enabled_only=True):

        aid = str(row.get("account_id") or "").strip()
        path = resolve_okx_config_path(aid)
        if not path:
            log.debug(
                "持仓历史跳过: %s 无密钥文件",
                _fmt_log_account_id(aid),
            )
            continue

        hist, err = okx_mod.okx_fetch_positions_history_contracts(config_path=path)
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
            "持仓历史: %s \t接口行=%d \t写入=%d",
            _fmt_log_account_id(aid),
            len(hist),
            n,
        )

    try:
        all_ids = [
            str(b["account_id"] or "").strip()
            for b in list_account_basics(enabled_only=False)
            if str(b.get("account_id") or "").strip()
        ]
        db_module.account_daily_close_performance_rebuild_for_accounts(
            all_ids, _account_benchmark_inst_map()
        )
    except Exception as ex:
        log.warning("account_daily_close_performance 重建失败: %s", ex)
        db_module.log_insert(
            "WARN",
            "account_daily_close_performance_rebuild_failed",
            source="account_mgr",
            extra={"error": str(ex)},
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
    br = okx_account_disabled_exchange_reason(aid)
    if br:
        return False, br
    path = resolve_okx_config_path(aid)
    if not path:
        return False, "未找到密钥配置"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    hist, err = okx_mod.okx_fetch_positions_history_contracts(config_path=path)
    if err:
        db_module.log_insert(
            "WARN",
            "positions_history_fetch_failed",
            source="account_mgr",
            extra={"account_id": aid, "error": err},
        )
        return False, err
    if not hist:
        try:
            db_module.account_daily_close_performance_rebuild_for_accounts(
                [aid], _account_benchmark_inst_map()
            )
        except Exception:
            pass
        return True, "无新历史仓位数据"
    n = db_module.account_positions_history_insert_batch(aid, hist, ts)
    log.info(
        "positions_history_one_ok: %s api_rows=%d inserted=%d",
        _fmt_log_account_id(aid),
        len(hist),
        n,
    )
    try:
        db_module.account_daily_close_performance_rebuild_for_accounts(
            [aid], _account_benchmark_inst_map()
        )
    except Exception as ex:
        log.warning("account_daily_close_performance 单账户重建失败 %s: %s", aid, ex)
    return True, f"已写入 {n} 条新记录"


# --- 实时查询（不入库） ---


def fetch_balance_live(account_id: str) -> dict | None:
    import exchange.okx as okx_mod

    if okx_account_disabled_exchange_reason(account_id):
        return None
    path = resolve_okx_config_path(account_id)
    if not path:
        return None
    return okx_mod.okx_fetch_balance(config_path=path)


def fetch_positions_live(account_id: str) -> tuple[list[dict], str | None]:
    import exchange.okx as okx_mod

    br = okx_account_disabled_exchange_reason(account_id)
    if br:
        return ([], br)
    path = resolve_okx_config_path(account_id)
    if not path:
        return ([], "账户未配置或密钥文件不存在")
    return okx_mod.okx_fetch_positions(config_path=path)


def fetch_ticker_for_inst(inst_id: str) -> float | None:
    import exchange.okx as okx_mod

    return okx_mod.okx_fetch_ticker(inst_id)


def fetch_pending_orders_live(account_id: str) -> tuple[list[dict], str | None]:
    import exchange.okx as okx_mod

    br = okx_account_disabled_exchange_reason(account_id)
    if br:
        return ([], br)
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
    prep: list[tuple[str, str, Any, Any, float, dict | None]] = []
    for row in rows:
        aid = str(row.get("account_id") or "").strip()
        ex_name = (row.get("exchange_account") or "OKX").strip()
        path = resolve_okx_config_path(aid)
        snap = db_module.account_snapshot_latest_by_account(aid)
        meta_row = db_module.account_meta_get(aid)
        initial = float(meta_row["initial_capital"]) if meta_row else _initial_capital(row)
        ym = datetime.now(timezone.utc).strftime("%Y-%m")
        month_row = db_module.account_month_open_get(aid, ym)
        prep.append((aid, ex_name, path, snap, initial, month_row))

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
    for aid, ex_name, path, snap, initial, month_row in prep:
        month_open = float(month_row["open_equity"]) if month_row else None
        month_open_cash = (
            float(month_row["open_cash"])
            if month_row and month_row.get("open_cash") is not None
            else None
        )
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
                    "month_open_cash": month_open_cash,
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
                    "month_open_cash": month_open_cash,
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
                    "month_open_cash": month_open_cash,
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
                "sandbox": okx_sandbox_from_key_file(
                    str(basic.get("account_key_file") or "")
                ),
            }
        )
    return out
