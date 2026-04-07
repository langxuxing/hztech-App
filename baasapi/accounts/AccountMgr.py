# -*- coding: utf-8 -*-
"""
从 Account_List.json 管理 OKX 账户：列表、密钥路径、余额快照（入库）、
行情/持仓/委托（仅实时查询，不入库）。

与 baasapi/main.py 集成：/api/account-profit、/api/tradingbots、按 account_id 的
positions / profit-history / ticker / pending-orders 等通过本模块解析密钥与账户元数据。

定时任务由 main 每 5 分钟调用，写入 SQLite：
- account_balance_snapshots：cash_balance=USDT 资产余额(cashBal)，available_margin=可用保证金(availEq)，used_margin=占用；equity_usdt=权益
- （已弃用 tradingbots.json；盈亏快照以 account_balance_snapshots 为准）
- OKX 当前持仓（每合约一行：多/空各计一条仓位腿 open_leg_count，张数与分项/合计未实现盈亏）→ account_open_positions_snapshots
- 定时余额写入后：按账户节流（默认至多每小时）检测近 92 日 UTC 是否缺日，若有则调 OKX bills-archive（USDT bal）补全 account_balance_snapshots；权益按最近快照 equity/可用保证金 比例估算；补全插入后重算相关账户的 account_daily_performance
- 多时点快照经 strategy_efficiency.daily_cash_delta_by_utc_day 汇总为 UTC 自然日现金增量，再算现金收益率%、策略能效
- OKX 历史仓位 → account_positions_history（SWAP+FUTURES 合并去重，深分页；自库内最大 uTime 起向前重叠 60s 增量拉取；
  统计口径与接口一致：时间用 uTime 平仓/更新时刻，非 cTime；净盈亏优先 realizedPnl）；
  再汇总写入 account_daily_performance（按北京时间日历日平仓净盈亏、权益口径日收益率%、对标 TR 近似映射）
- 各账户静态字段（与 SQLite account_list 同步）；UTC 每月 1 日 00:10 定时任务写入 account_month_open（不再由余额同步顺带插入）
"""
from __future__ import annotations

import importlib.util
import logging
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

ACCOUNTS_DIR = Path(__file__).resolve().parent

# ccxt.okx 按密钥文件路径缓存在 exchange.okx（见 get_okx_ccxt_exchange_for_config_path）

# 定时任务 DEBUG 日志：账户列宽（超长截断后左对齐）
_LOG_ACCOUNT_COL_WIDTH = 20
# 历史仓位增量拉取：以库内最大 uTime 为基准再向前重叠，避免漏单与重复全量分页
_POSITIONS_HISTORY_OVERLAP_MS = 60_000
_BILLS_BACKFILL_MIN_INTERVAL_SEC = 3600.0
_BILLS_BACKFILL_LOOKBACK_DAYS = 92
_last_okx_bills_backfill_monotonic: dict[str, float] = {}


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


def get_okx_ccxt_exchange_for_config_path(config_path: Path | None) -> Any | None:
    """账户级 OKX ccxt 连接：按密钥文件路径单例复用，勿在业务代码中重复 ``ccxt.okx()``。

    与 ``exchange.okx.get_ccxt_okx_exchange`` 同一缓存；密钥文件 mtime 变化后自动重建。
    """
    import exchange.okx as okx_mod

    return okx_mod.get_ccxt_okx_exchange(config_path)


def invalidate_okx_ccxt_exchange_cache(config_path: Path | None = None) -> None:
    """清除 OKX ccxt 缓存（换钥后可调用；不传 path 则清空全部）。"""
    import exchange.okx as okx_mod

    okx_mod.invalidate_ccxt_okx_exchange_cache(config_path)


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


def _okx_balance_amounts(live: dict) -> tuple[float, float, float, float]:
    """OKX 聚合：权益、USDT 资产余额 cashBal、可用保证金 availEq、占用。"""
    eq = float(live.get("equity_usdt") or live.get("total_eq") or 0.0)
    cash_bal = float(live.get("cash_balance") or 0.0)
    avail = float(live.get("available_margin") or live.get("avail_eq") or 0.0)
    used = float(live.get("used_margin") or 0.0)
    return eq, cash_bal, avail, used


def profit_vs_initial(initial: float, equity_usdt: float) -> tuple[float, float]:
    """权益相对期初 account_list.initial_capital：收益额、收益率%。"""
    ini = float(initial)
    pa = float(equity_usdt) - ini
    if abs(ini) <= 1e-18:
        return pa, 0.0
    return pa, pa / ini * 100.0


def cash_profit_vs_initial(initial: float, cash_balance: float) -> tuple[float, float]:
    """USDT 资产余额（OKX cashBal）相对期初：收益额、收益率%。"""
    ini = float(initial)
    pa = float(cash_balance) - ini
    if abs(ini) <= 1e-18:
        return pa, 0.0
    return pa, pa / ini * 100.0


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


def account_list_row_by_id(account_id: str) -> dict[str, Any] | None:
    """account_id 对应 Account_List.json 中的一行；不存在则 None。"""
    aid = str(account_id or "").strip()
    if not aid:
        return None
    for row in load_account_list():
        if str(row.get("account_id") or "").strip() == aid:
            return row
    return None


def is_account_disabled_in_account_list(account_id: str) -> bool:
    """若在 Account_List 中存在且 enbaled/enabled/enable 为关闭，则 True。"""
    row = account_list_row_by_id(account_id)
    if row is None:
        return False
    return not _account_row_enabled(row)


def sync_account_list_from_json(db_module: Any) -> None:
    """将 Account_List.json 全量同步到 SQLite account_list（与 JSON 字段一致）。"""
    for row in load_account_list():
        aid = str(row.get("account_id") or "").strip()
        if not aid:
            continue
        db_module.account_list_upsert(
            aid,
            _initial_capital(row),
            account_name=(row.get("account_name") or "").strip(),
            exchange_account=(row.get("exchange_account") or "").strip(),
            symbol=(row.get("symbol") or "").strip(),
            trading_strategy=(row.get("trading_strategy") or "").strip(),
            account_key_file=(row.get("account_key_file") or "").strip(),
            script_file=(row.get("script_file") or "").strip(),
            enabled=_account_row_enabled(row),
        )


def sync_account_list_after_account_list_write(db_module: Any) -> None:
    """管理员写入 Account_List.json 后调用：按 JSON 同步各账户行，并删除已从列表移除的库行。"""
    sync_account_list_from_json(db_module)
    valid_ids = {
        str(r.get("account_id") or "").strip()
        for r in load_account_list()
        if str(r.get("account_id") or "").strip()
    }
    db_module.account_list_prune_except(valid_ids)


def run_account_month_open_rollover(
    db_module: Any, logger: logging.Logger | None = None
) -> None:
    """UTC 每月 1 日 00:10 定时：拉取各启用账户 OKX 余额，upsert 当月 account_month_open。"""
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    sync_account_list_from_json(db_module)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    ym = datetime.now(timezone.utc).strftime("%Y-%m")
    for row in iter_okx_accounts(enabled_only=True):
        aid = str(row.get("account_id") or "").strip()
        path = resolve_okx_config_path(aid)
        if not path:
            log.debug(
                "account_month_open 跳过: %s 无密钥文件",
                _fmt_log_account_id(aid),
            )
            continue
        live = okx_mod.okx_fetch_balance(config_path=path)
        if not live:
            db_module.log_insert(
                "WARN",
                "account_month_open_skip",
                source="account_mgr",
                extra={
                    "account_id": aid,
                    "year_month": ym,
                    "reason": "balance_fetch_failed",
                },
            )
            continue
        total_eq, cash_bal, avail_eq, used_m = _okx_balance_amounts(live)
        db_module.account_month_open_upsert(
            aid, ym, total_eq, ts, initial_balance=cash_bal
        )
        log.info(
            "account_month_open: %s ym=%s equity=%s cash_bal=%s avail=%s used=%s",
            _fmt_log_account_id(aid),
            ym,
            int(round(total_eq)),
            int(round(cash_bal)),
            int(round(avail_eq)),
            int(round(used_m)),
        )


def refresh_all_balance_snapshots(db_module: Any, logger: logging.Logger | None = None) -> None:
    """
    拉取各 OKX 账户余额并写入 account_balance_snapshots。
    当月月初 open_equity / initial_balance（原 open_cash）由 UTC 每月 1 日 00:10 定时任务写入 account_month_open。
    应在定时器内调用（建议每 5 分钟）。

    每个成功拉取余额的账户：至多每小时检测近 92 个 UTC 自然日是否缺快照行；有缺则调
    bills-archive 补全。若某账户本次补全有新插入，周期末会对这些账户重算
    account_daily_performance（同一周期内后续 refresh_all_positions_history 仍会全量重建 ADP，结果一致）。
    """
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    sync_account_list_from_json(db_module)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    accounts_adp: set[str] = set()

    for row in iter_okx_accounts(enabled_only=True):
        aid = str(row.get("account_id") or "").strip()
        path = resolve_okx_config_path(aid)
        meta = db_module.account_list_get(aid)
        initial = float(meta["initial_capital"]) if meta else _initial_capital(row)

        if not path:
            log.debug(
                "账户快照跳过: %s 无密钥文件",
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

        total_eq, cash_bal, avail_eq, used_m = _okx_balance_amounts(live)
        profit_amount, profit_percent = profit_vs_initial(initial, total_eq)
        cash_profit_amount, cash_profit_percent = cash_profit_vs_initial(
            initial, cash_bal
        )

        db_module.account_snapshot_insert(
            account_id=aid,
            snapshot_at=ts,
            cash_balance=cash_bal,
            equity_usdt=total_eq,
            profit_amount=profit_amount,
            profit_percent=profit_percent,
            available_margin=avail_eq,
            used_margin=used_m,
            cash_profit_amount=cash_profit_amount,
            cash_profit_percent=cash_profit_percent,
        )

        log.debug(
            "账户快照: %s \t权益:=%d \t资产:=%d \t可用:=%d \t占用:=%d",
            _fmt_log_account_id(aid),
            int(round(total_eq)),
            int(round(cash_bal)),
            int(round(avail_eq)),
            int(round(used_m)),
        )

        try:
            now_mono = time.monotonic()
            last = _last_okx_bills_backfill_monotonic.get(aid)
            if last is not None and (now_mono - last) < _BILLS_BACKFILL_MIN_INTERVAL_SEC:
                pass
            else:
                if not db_module.account_balance_snapshots_has_gap_in_recent_utc_days(
                    aid, _BILLS_BACKFILL_LOOKBACK_DAYS
                ):
                    _last_okx_bills_backfill_monotonic[aid] = now_mono
                else:
                    _last_okx_bills_backfill_monotonic[aid] = now_mono
                    n_b, _bf = backfill_account_snapshots_from_okx_bills(
                        db_module, aid, log, days=_BILLS_BACKFILL_LOOKBACK_DAYS
                    )
                    if n_b > 0:
                        accounts_adp.add(aid)
        except Exception as e:
            log.warning(
                "balance_snapshots_bills_backfill_failed: %s %s",
                _fmt_log_account_id(aid),
                e,
            )

    if accounts_adp:
        rebuild_account_daily_performance_safe(db_module, sorted(accounts_adp), log)


def backfill_account_snapshots_from_okx_bills(
    db_module: Any,
    account_id: str,
    logger: logging.Logger | None = None,
    *,
    days: int = 40,
) -> tuple[int, str]:
    """用 OKX ``/api/v5/account/bills-archive`` 的 USDT ``bal`` 补全近期缺日快照。

    写入 SQLite 表 ``account_balance_snapshots``（UTC 自然日）。函数名保留 ``account_snapshots`` 片段仅为兼容旧调用。

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

    meta = db_module.account_list_get(aid)
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
        avail_prev = float(prev["available_margin"]) if prev else 0.0
        if avail_prev <= 1e-12 and prev is not None:
            avail_prev = float(prev.get("cash_balance") or 0.0)
        eq_prev = float(prev["equity_usdt"]) if prev else 0.0
        ratio = (eq_prev / avail_prev) if avail_prev > 1e-12 else 1.0
        equity = cash_b * ratio
        profit_amount, profit_percent = profit_vs_initial(initial, equity)
        cash_profit_amount, cash_profit_percent = cash_profit_vs_initial(
            initial, cash_b
        )
        snap_at = f"{day_s}T23:59:59.000000Z"
        db_module.account_snapshot_insert(
            account_id=aid,
            snapshot_at=snap_at,
            cash_balance=cash_b,
            equity_usdt=equity,
            profit_amount=profit_amount,
            profit_percent=profit_percent,
            available_margin=0.0,
            used_margin=0.0,
            cash_profit_amount=cash_profit_amount,
            cash_profit_percent=cash_profit_percent,
        )
        inserted += 1
        cur_d = cur_d + timedelta(days=1)

    return inserted, f"插入 {inserted} 条缺日快照"


def refresh_balance_snapshot_one(
    db_module: Any, account_id: str, logger: logging.Logger | None = None
) -> tuple[bool, str]:
    """
    从 OKX 拉取单账户余额，写入 account_balance_snapshots（资产余额、可用保证金、占用、权益）。
    当月月初 account_month_open 由定时任务写入；本函数不写入月初表。
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

    meta = db_module.account_list_get(aid)
    initial = float(meta["initial_capital"]) if meta else 0.0
    if initial <= 0:
        for row in iter_okx_accounts(enabled_only=False):
            if str(row.get("account_id") or "").strip() == aid:
                initial = _initial_capital(row)
                break

    sync_account_list_from_json(db_module)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")

    live = okx_mod.okx_fetch_balance(config_path=path)
    if not live:
        return False, "OKX 余额拉取失败"

    total_eq, cash_bal, avail_eq, used_m = _okx_balance_amounts(live)
    profit_amount, profit_percent = profit_vs_initial(initial, total_eq)
    cash_profit_amount, cash_profit_percent = cash_profit_vs_initial(
        initial, cash_bal
    )

    db_module.account_snapshot_insert(
        account_id=aid,
        snapshot_at=ts,
        cash_balance=cash_bal,
        equity_usdt=total_eq,
        profit_amount=profit_amount,
        profit_percent=profit_percent,
        available_margin=avail_eq,
        used_margin=used_m,
        cash_profit_amount=cash_profit_amount,
        cash_profit_percent=cash_profit_percent,
    )

    log.info(
        "balance_snapshot_one_ok: %s equity=%s cash_bal=%s avail=%s used=%s",
        _fmt_log_account_id(aid),
        int(round(total_eq)),
        int(round(cash_bal)),
        int(round(avail_eq)),
        int(round(used_m)),
    )
    try:
        n_b, _bf = backfill_account_snapshots_from_okx_bills(
            db_module, aid, log, days=_BILLS_BACKFILL_LOOKBACK_DAYS
        )
    except Exception as e:
        log.warning(
            "balance_snapshot_bills_backfill_failed: %s %s",
            _fmt_log_account_id(aid),
            e,
        )
        n_b = 0
    if n_b > 0:
        rebuild_account_daily_performance_safe(db_module, [aid], log)
        return True, (
            "已写入 account_balance_snapshots；OKX 账单已补全 "
            f"{n_b} 个缺日并已重算 account_daily_performance"
        )
    return True, "已写入 account_balance_snapshots"


def _load_tradingbots_json_bots() -> list[dict]:
    """已弃用 accounts/tradingbots.json；账户仅以 Account_List.json 为准。"""
    return []


def fetch_and_save_tradingbot_snapshots(
    db_module: Any, logger: logging.Logger | None = None
) -> None:
    """兼容入口：原 tradingbots.json 路径已弃用，此函数不再写入数据。"""
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
    """遗留：原 tradingbots-only bot 的余额写入 tradingbot_profit_snapshots（当前无数据源）。"""
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
    return True, "已写入 tradingbot_profit_snapshots"


def _account_benchmark_inst_map() -> dict[str, str]:
    """account_id → Account_List.symbol（作 market_daily_bars 对标 TR），空则用库表重建时的默认值。"""
    return {
        str(b["account_id"] or "").strip(): (b.get("symbol") or "").strip()
        for b in list_account_basics(enabled_only=False)
        if str(b.get("account_id") or "").strip()
    }


def rebuild_account_daily_performance_safe(
    db_module: Any,
    account_ids: list[str],
    logger: logging.Logger | None = None,
) -> None:
    """按 account_positions_history 重算给定账户的 account_daily_performance；失败仅记录日志。"""
    log = logger or logging.getLogger(__name__)
    ids = [str(i).strip() for i in (account_ids or []) if str(i).strip()]
    if not ids:
        return
    try:
        db_module.account_daily_performance_rebuild_for_accounts(
            ids, _account_benchmark_inst_map()
        )
    except Exception as ex:
        log.warning("account_daily_performance 重建失败: %s", ex)
        try:
            db_module.log_insert(
                "WARN",
                "account_daily_performance_rebuild_failed",
                source="account_mgr",
                extra={"error": str(ex), "account_ids": ids[:30]},
            )
        except Exception:
            pass


def refresh_all_positions_history(
    db_module: Any, logger: logging.Logger | None = None
) -> None:
    """
    拉取 Account_List 中已启用（enbaled=true）OKX 账户的 positions-history：
    SWAP + FUTURES 合并去重、深分页写入 account_positions_history；
    最后按账户重算 account_daily_performance。
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

        min_ut = _positions_history_min_u_time_ms_for_incremental(db_module, aid)
        hist, err = okx_mod.okx_fetch_positions_history_contracts(
            config_path=path, min_u_time_ms=min_ut
        )
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
            "持仓历史: %s \t读取行:=%d \t写入行：=%d",
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
        db_module.account_daily_performance_rebuild_for_accounts(
            all_ids, _account_benchmark_inst_map()
        )
    except Exception as ex:
        log.warning("account_daily_performance 重建失败: %s", ex)
        db_module.log_insert(
            "WARN",
            "account_daily_performance_rebuild_failed",
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
    min_ut = _positions_history_min_u_time_ms_for_incremental(db_module, aid)
    hist, err = okx_mod.okx_fetch_positions_history_contracts(
        config_path=path, min_u_time_ms=min_ut
    )
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
            db_module.account_daily_performance_rebuild_for_accounts(
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
        db_module.account_daily_performance_rebuild_for_accounts(
            [aid], _account_benchmark_inst_map()
        )
    except Exception as ex:
        log.warning("account_daily_performance 单账户重建失败 %s: %s", aid, ex)
    return True, f"已写入 {n} 条新记录"


def _positions_history_min_u_time_ms_for_incremental(
    db_module: Any, account_id: str
) -> int | None:
    """库内该账户最大 u_time_ms 减去重叠窗口；无历史则全量拉取（返回 None）。"""
    try:
        mx = db_module.account_positions_history_max_u_time_ms(account_id)
    except Exception:
        return None
    if mx is None or mx <= 0:
        return None
    return max(0, int(mx) - _POSITIONS_HISTORY_OVERLAP_MS)


_OPEN_LEG_EPS = 1e-12


def aggregate_open_positions_by_inst(positions: list[dict]) -> list[dict]:
    """将 okx_fetch_positions 归一化行按 inst_id 聚合为一条记录：多/空张数、各侧 UPL、open_leg_count（多/空非零各计 1 腿）。"""
    by_inst: dict[str, dict[str, Any]] = {}
    for p in positions or []:
        inst = str(p.get("inst_id") or "").strip()
        if not inst:
            continue
        side = str(p.get("pos_side") or "long").lower()
        if side not in ("long", "short"):
            side = "long"
        pos = float(p.get("pos") or 0)
        upl = float(p.get("upl") or 0)
        mark_px = float(p.get("mark_px") or 0)
        last_px = float(p.get("last_px") or 0)
        if inst not in by_inst:
            by_inst[inst] = {
                "inst_id": inst,
                "long_pos_size": 0.0,
                "short_pos_size": 0.0,
                "long_upl": 0.0,
                "short_upl": 0.0,
                "long_cost_notional": 0.0,
                "short_cost_notional": 0.0,
                "mark_px": 0.0,
                "last_px": 0.0,
            }
        g = by_inst[inst]
        abs_pos = abs(pos)
        avg_px = float(p.get("avg_px") or 0)
        if side == "long":
            g["long_pos_size"] += abs_pos
            g["long_upl"] += upl
            if avg_px > 0 and abs_pos > _OPEN_LEG_EPS:
                g["long_cost_notional"] += abs_pos * avg_px
        else:
            g["short_pos_size"] += abs_pos
            g["short_upl"] += upl
            if avg_px > 0 and abs_pos > _OPEN_LEG_EPS:
                g["short_cost_notional"] += abs_pos * avg_px
        if mark_px > 0:
            g["mark_px"] = mark_px
        if last_px > 0:
            g["last_px"] = last_px
    out: list[dict] = []
    for g in by_inst.values():
        g["total_upl"] = float(g["long_upl"]) + float(g["short_upl"])
        lp = float(g["long_pos_size"])
        sp = float(g["short_pos_size"])
        lc = float(g.get("long_cost_notional") or 0)
        sc = float(g.get("short_cost_notional") or 0)
        g["long_avg_px"] = lc / lp if lp > _OPEN_LEG_EPS else 0.0
        g["short_avg_px"] = sc / sp if sp > _OPEN_LEG_EPS else 0.0
        g["open_leg_count"] = (1 if lp > _OPEN_LEG_EPS else 0) + (
            1 if sp > _OPEN_LEG_EPS else 0
        )
        out.append(g)
    out.sort(key=lambda x: str(x.get("inst_id") or ""))
    return out


def refresh_all_open_positions_snapshots(
    db_module: Any, logger: logging.Logger | None = None
) -> None:
    """
    拉取各启用 OKX 账户当前持仓，按合约聚合（每合约一行，多空各算一条腿）写入 account_open_positions_snapshots。
    与 refresh_all_balance_snapshots 同周期调用（main 定时器）。
    """
    log = logger or logging.getLogger(__name__)
    import exchange.okx as okx_mod

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    for row in iter_okx_accounts(enabled_only=True):
        aid = str(row.get("account_id") or "").strip()
        path = resolve_okx_config_path(aid)
        if not path:
            log.debug(
                "持仓快照跳过: %s 无密钥文件",
                _fmt_log_account_id(aid),
            )
            continue
        positions, err = okx_mod.okx_fetch_positions(config_path=path)
        if err:
            db_module.log_insert(
                "WARN",
                "open_positions_snapshot_fetch_failed",
                source="account_mgr",
                extra={"account_id": aid, "error": err},
            )
            continue
        agg = aggregate_open_positions_by_inst(positions or [])
        if not agg:
            continue
        n = db_module.account_open_positions_snapshots_insert_batch(aid, ts, agg)
        sum_long = sum(float(g.get("long_pos_size") or 0) for g in agg)
        sum_short = sum(float(g.get("short_pos_size") or 0) for g in agg)
        n_legs = sum(int(g.get("open_leg_count") or 0) for g in agg)
        log.debug(
            "当前持仓: %s \t产品：=%d \t仓位腿：=%d \t多:=%.6g \t空:=%.6g \t写入行：=%d",
            _fmt_log_account_id(aid),
            len(agg),
            n_legs,
            sum_long,
            sum_short,
            n,
        )


def refresh_open_positions_snapshot_one(
    db_module: Any, account_id: str, logger: logging.Logger | None = None
) -> tuple[bool, str]:
    """单账户拉取当前持仓并写入 account_open_positions_snapshots（管理员手动同步）。"""
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
    positions, err = okx_mod.okx_fetch_positions(config_path=path)
    if err:
        db_module.log_insert(
            "WARN",
            "open_positions_snapshot_fetch_failed",
            source="account_mgr",
            extra={"account_id": aid, "error": err},
        )
        return False, err
    agg = aggregate_open_positions_by_inst(positions or [])
    if not agg:
        return True, "当前无持仓，未写入快照行"
    n = db_module.account_open_positions_snapshots_insert_batch(aid, ts, agg)
    n_legs = sum(int(g.get("open_leg_count") or 0) for g in agg)
    log.info(
        "open_positions_snapshot_one_ok: %s products=%d legs=%d rows=%d",
        _fmt_log_account_id(aid),
        len(agg),
        n_legs,
        n,
    )
    return True, f"已写入 account_open_positions_snapshots（{n} 行）"


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
    prep: list[tuple[str, str, Any, Any, float, dict | None, str]] = []
    for row in rows:
        aid = str(row.get("account_id") or "").strip()
        ex_name = (row.get("exchange_account") or "OKX").strip()
        acc_name = (row.get("account_name") or "").strip()
        path = resolve_okx_config_path(aid)
        snap = db_module.account_snapshot_latest_by_account(aid)
        meta_row = db_module.account_list_get(aid)
        initial = float(meta_row["initial_capital"]) if meta_row else _initial_capital(row)
        ym = datetime.now(timezone.utc).strftime("%Y-%m")
        month_row = db_module.account_month_open_get(aid, ym)
        prep.append((aid, ex_name, path, snap, initial, month_row, acc_name))

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
    for aid, ex_name, path, snap, initial, month_row, acc_name in prep:
        month_open = float(month_row["open_equity"]) if month_row else None
        month_open_cash = (
            float(month_row["initial_balance"])
            if month_row and month_row.get("initial_balance") is not None
            else None
        )
        live = live_by_aid.get(aid) if path else None
        if live:
            total_eq, cash_bal, avail_eq, used_m = _okx_balance_amounts(live)
            upl = float(live.get("upl") or 0.0)
            profit_amount, profit_percent = profit_vs_initial(initial, total_eq)
            cash_profit_amount, cash_profit_percent = cash_profit_vs_initial(
                initial, cash_bal
            )
            out.append(
                {
                    "bot_id": aid,
                    "account_id": aid,
                    "account_name": acc_name,
                    "exchange_account": ex_name,
                    "initial_balance": initial,
                    "current_balance": total_eq,
                    "profit_amount": profit_amount,
                    "profit_percent": profit_percent,
                    "cash_profit_amount": cash_profit_amount,
                    "cash_profit_percent": cash_profit_percent,
                    "floating_profit": upl,
                    "equity_usdt": total_eq,
                    "balance_usdt": cash_bal,
                    "cash_balance": cash_bal,
                    "available_margin": avail_eq,
                    "used_margin": used_m,
                    "snapshot_time": snap["snapshot_at"] if snap else None,
                    "month_open_equity": month_open,
                    "month_open_cash": month_open_cash,
                }
            )
        elif snap:
            eq = float(snap["equity_usdt"])
            cash_bal = float(snap.get("cash_balance") or 0.0)
            avail_eq = float(snap.get("available_margin") or 0.0)
            used_m = float(snap.get("used_margin") or 0.0)
            if avail_eq <= 1e-12:
                avail_eq = cash_bal
            cpa = snap.get("cash_profit_amount")
            cpp = snap.get("cash_profit_percent")
            if cpa is None or cpp is None:
                cpa, cpp = cash_profit_vs_initial(initial, cash_bal)
            else:
                cpa, cpp = float(cpa), float(cpp)
            out.append(
                {
                    "bot_id": aid,
                    "account_id": aid,
                    "account_name": acc_name,
                    "exchange_account": ex_name,
                    "initial_balance": initial,
                    "current_balance": eq,
                    "profit_amount": float(snap["profit_amount"]),
                    "profit_percent": float(snap["profit_percent"]),
                    "cash_profit_amount": cpa,
                    "cash_profit_percent": cpp,
                    "floating_profit": 0.0,
                    "equity_usdt": eq,
                    "balance_usdt": cash_bal,
                    "cash_balance": cash_bal,
                    "available_margin": avail_eq,
                    "used_margin": used_m,
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
                    "account_name": acc_name,
                    "exchange_account": ex_name,
                    "initial_balance": initial,
                    "current_balance": 0,
                    "profit_amount": 0,
                    "profit_percent": 0,
                    "cash_profit_amount": 0,
                    "cash_profit_percent": 0,
                    "floating_profit": 0,
                    "equity_usdt": 0,
                    "balance_usdt": 0,
                    "cash_balance": 0.0,
                    "available_margin": 0.0,
                    "used_margin": 0.0,
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
