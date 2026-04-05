# -*- coding: utf-8 -*-
"""
按 UTC 自然日汇总账户快照中的现金余额变化，并与 OKX 日线价格波动（|高−低|，非负）对齐。
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


def merge_daily_efficiency_rows(
    market_bars: list[dict[str, Any]],
    cash_by_day: dict[str, dict[str, float]],
) -> list[dict[str, Any]]:
    """合并 OKX 日线波动（|高−低|，非负）与现金日增量（非负），并计算 tr_pct、能效比。"""
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
        cash_delta_pct = None
        if cash_info and sod_cash is not None and float(sod_cash) > 0 and cash_delta is not None:
            cash_delta_pct = float(cash_delta) / float(sod_cash) * 100.0
        # 能效比值 = 每日现金增量(USDT) / 当日价格波动幅度 |高−低| × 1e-7
        eff = None
        if cash_delta is not None and tr > 1e-18:
            eff = float(cash_delta) / float(tr) * 1e-7
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
                "efficiency_ratio": eff,
            }
        )
    rows.sort(key=lambda x: x["day"], reverse=True)
    return rows
