# -*- coding: utf-8 -*-
"""
按 UTC 自然日汇总账户快照中的现金余额变化，并与 OKX 日线对齐。
输出含：每日波动率%（|高−低|/收盘）、现金收益率%（日增量÷UTC 自然月月初资金×100，无月初则用当日 sod）、
策略能效（日增量 USDT÷(波幅×1e9)）。日线波动数据由 market_daily_bars 全站缓存，各账户共用。
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any


def _parse_snapshot_ts(raw: str) -> datetime | None:
    s = (raw or "").strip()
    if len(s) < 10:
        return None
    try:
        if s.endswith("Z"):
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        if " " in s and "T" not in s:
            s = s.replace(" ", "T", 1)
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            return dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


def daily_cash_delta_by_utc_day(snapshots: list[dict[str, Any]]) -> dict[str, dict[str, float]]:
    """
    对每个 UTC 日 D：sod_cash = D 开始前最后一条快照的 cash_balance；
    eod_cash = D 日内（含）最后一条快照的 cash_balance。
    现金余额（availEq 口径）按非负处理；日变动 cash_delta_usdt = max(0, eod - sod)，
    不出现负值（仅反映当日余额相对日初的**增加**部分）。
    仅返回当日至少有一条快照的日期。
    """
    points: list[tuple[datetime, float]] = []
    for r in snapshots:
        ts = _parse_snapshot_ts(str(r.get("snapshot_at") or ""))
        if ts is None:
            continue
        try:
            cash = float(r.get("cash_balance") or 0.0)
        except (TypeError, ValueError):
            cash = 0.0
        cash = max(0.0, cash)
        points.append((ts, cash))
    if not points:
        return {}
    points.sort(key=lambda x: x[0])

    days_with_data: set[str] = set()
    for ts, _ in points:
        days_with_data.add(ts.strftime("%Y-%m-%d"))

    sorted_days = sorted(days_with_data)
    out: dict[str, dict[str, float]] = {}
    for d in sorted_days:
        y, m, dd = (int(x) for x in d.split("-"))
        day_start = datetime(y, m, dd, tzinfo=timezone.utc)
        day_end = day_start + timedelta(days=1)
        sod: float | None = None
        for ts, cash in points:
            if ts < day_start:
                sod = cash
        first_on_day: float | None = None
        last_on_day: float | None = None
        for ts, cash in points:
            if day_start <= ts < day_end:
                if first_on_day is None:
                    first_on_day = cash
                last_on_day = cash
        if last_on_day is None:
            continue
        if sod is None:
            sod = first_on_day if first_on_day is not None else last_on_day
        eod = last_on_day
        sod = max(0.0, float(sod))
        eod = max(0.0, float(eod))
        delta_raw = eod - sod
        cash_delta = max(0.0, delta_raw)
        out[d] = {
            "sod_cash": sod,
            "eod_cash": eod,
            "cash_delta_usdt": cash_delta,
        }
    return out


def month_start_cash_by_month_from_snapshots(
    snapshots: list[dict[str, Any]],
) -> dict[str, float]:
    """
    每个 UTC 自然月 YYYY-MM 对应「月初」资金：
    该月 1 日 00:00 UTC 之前最后一笔快照的 cash_balance；
    若该月前无任何快照，则取该月内最早一条快照余额（新户首月）。
    """
    points: list[tuple[datetime, float]] = []
    for r in snapshots:
        ts = _parse_snapshot_ts(str(r.get("snapshot_at") or ""))
        if ts is None:
            continue
        try:
            cash = float(r.get("cash_balance") or 0.0)
        except (TypeError, ValueError):
            cash = 0.0
        cash = max(0.0, cash)
        points.append((ts, cash))
    if not points:
        return {}
    points.sort(key=lambda x: x[0])
    ym_set = {(ts.year, ts.month) for ts, _ in points}
    out: dict[str, float] = {}
    for y, m in sorted(ym_set):
        boundary = datetime(y, m, 1, tzinfo=timezone.utc)
        last_before: float | None = None
        for ts, cash in points:
            if ts < boundary:
                last_before = cash
        key = f"{y:04d}-{m:02d}"
        if last_before is not None:
            out[key] = max(0.0, float(last_before))
        else:
            for ts, cash in points:
                if ts.year == y and ts.month == m:
                    out[key] = max(0.0, float(cash))
                    break
    return out


def merge_daily_efficiency_rows(
    market_bars: list[dict[str, Any]],
    cash_by_day: dict[str, dict[str, float]],
    month_base_by_month: dict[str, float] | None = None,
) -> list[dict[str, Any]]:
    """合并日线波动（|高−低|，非负）与现金日增量（非负），并计算 tr_pct、现金收益率%、策略能效。"""
    rows: list[dict[str, Any]] = []
    for bar in market_bars:
        day = str(bar.get("day") or "")
        if not day:
            continue
        close = float(bar.get("close") or 0.0)
        tr = max(0.0, float(bar.get("tr") or 0.0))
        tr_pct = (tr / close * 100.0) if close > 0 else None
        cash_info = cash_by_day.get(day)
        cash_delta = cash_info["cash_delta_usdt"] if cash_info else None
        sod_cash = cash_info["sod_cash"] if cash_info else None
        # 现金收益率% = 当日合约侧现金增量(USDT) ÷ 当 UTC 自然月月初资金 × 100
        month_key = day[:7] if len(day) >= 7 else ""
        month_base: float | None = None
        if month_base_by_month and month_key:
            mb = month_base_by_month.get(month_key)
            if mb is not None and float(mb) > 0:
                month_base = float(mb)
        yield_from_month_start = month_base is not None
        if month_base is None and cash_info and sod_cash is not None and float(sod_cash) > 0:
            month_base = float(sod_cash)
        cash_delta_pct = None
        month_start_cash_out: float | None = None
        if cash_delta is not None and month_base is not None and month_base > 0:
            cash_delta_pct = float(cash_delta) / month_base * 100.0
            if yield_from_month_start:
                month_start_cash_out = month_base
        # 策略能效 = 每日现金增量(USDT) / (当日价格波动幅度 |高−低| × 1e9)
        eff = None
        if cash_delta is not None and tr > 1e-18:
            eff = float(cash_delta) / (float(tr) * 1e9)
        rows.append(
            {
                "day": day,
                "open": float(bar.get("open") or 0.0),
                "high": float(bar.get("high") or 0.0),
                "low": float(bar.get("low") or 0.0),
                "close": close,
                "tr": tr,
                "tr_pct": tr_pct,
                "sod_cash": sod_cash,
                "eod_cash": cash_info["eod_cash"] if cash_info else None,
                "cash_delta_usdt": cash_delta,
                "cash_delta_pct": cash_delta_pct,
                "month_start_cash": month_start_cash_out,
                "efficiency_ratio": eff,
            }
        )
    rows.sort(key=lambda x: x["day"], reverse=True)
    return rows


def _utc_today_str() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def _utc_yesterday_str() -> str:
    return (datetime.now(timezone.utc).date() - timedelta(days=1)).isoformat()


def ensure_shared_market_daily_bars(
    db_mod: Any,
    okx_mod: Any,
    inst_id: str,
    *,
    backfill_limit: int = 400,
) -> str | None:
    """
    若库中缺少 UTC「昨日」日线，则从 OKX 拉取一段历史并写入 market_daily_bars。
    供 Account 定时同步与策略能效接口共用，避免每账户重复请求行情。
    """
    inst_id = (inst_id or "").strip()
    if not inst_id:
        return "empty inst_id"
    yday = _utc_yesterday_str()
    if db_mod.market_daily_bars_has_day(inst_id, yday):
        return None
    bars, err = okx_mod.okx_fetch_daily_ohlcv_with_tr(inst_id, limit=backfill_limit)
    if err:
        return err
    if not bars:
        return "no market bars"
    for b in bars:
        d = str(b.get("day") or "")
        if not d:
            continue
        db_mod.market_daily_bars_upsert(
            inst_id,
            d,
            float(b.get("open") or 0.0),
            float(b.get("high") or 0.0),
            float(b.get("low") or 0.0),
            float(b.get("close") or 0.0),
            max(0.0, float(b.get("tr") or 0.0)),
        )
    return None


def _upsert_okx_bars(db_mod: Any, inst_id: str, bars: list[dict[str, Any]]) -> None:
    for b in bars:
        d = str(b.get("day") or "")
        if not d:
            continue
        db_mod.market_daily_bars_upsert(
            inst_id,
            d,
            float(b.get("open") or 0.0),
            float(b.get("high") or 0.0),
            float(b.get("low") or 0.0),
            float(b.get("close") or 0.0),
            max(0.0, float(b.get("tr") or 0.0)),
        )


def load_market_bars_for_efficiency(
    db_mod: Any,
    okx_mod: Any,
    inst_id: str,
    days: int,
) -> tuple[list[dict[str, Any]], str | None]:
    """
    返回与 merge_daily_efficiency_rows 兼容的升序 K 线列表（优先读库，必要时拉 OKX 尾段补「当日」）。
    """
    inst_id = (inst_id or "").strip()
    if not inst_id:
        return [], "empty inst_id"
    days = max(7, min(366, int(days)))
    span = days + 12
    min_day = (datetime.now(timezone.utc).date() - timedelta(days=span)).isoformat()

    miss_err = ensure_shared_market_daily_bars(db_mod, okx_mod, inst_id)
    bars = db_mod.market_daily_bars_list_since(inst_id, min_day)
    today = _utc_today_str()

    need_tail = not bars or str(bars[-1].get("day") or "") < today
    if need_tail:
        tail, terr = okx_mod.okx_fetch_daily_ohlcv_with_tr(
            inst_id, limit=min(20, days + 8)
        )
        if terr:
            if not bars:
                return [], terr
        elif tail:
            _upsert_okx_bars(db_mod, inst_id, tail)
            bars = db_mod.market_daily_bars_list_since(inst_id, min_day)

    if not bars:
        fb, ferr = okx_mod.okx_fetch_daily_ohlcv_with_tr(inst_id, limit=days + 8)
        if ferr:
            return [], ferr or miss_err
        if not fb:
            return [], miss_err or "no market data"
        _upsert_okx_bars(db_mod, inst_id, fb)
        bars = db_mod.market_daily_bars_list_since(inst_id, min_day)

    cap = days + 10
    if len(bars) > cap:
        bars = bars[-cap:]
    return bars, None
