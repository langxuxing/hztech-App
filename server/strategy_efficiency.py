# -*- coding: utf-8 -*-
"""
按 UTC 自然日汇总账户快照中的现金余额变化，并与 OKX 日线 TR 对齐。
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
    eod_cash = D 日内（含）最后一条快照的 cash_balance；delta = eod - sod。
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
        out[d] = {
            "sod_cash": float(sod),
            "eod_cash": float(eod),
            "cash_delta_usdt": float(eod) - float(sod),
        }
    return out


def merge_daily_efficiency_rows(
    market_bars: list[dict[str, Any]],
    cash_by_day: dict[str, dict[str, float]],
) -> list[dict[str, Any]]:
    """合并 OKX 日线 TR 与现金日增量，并计算 tr_pct、现金变动比例、效率比。"""
    rows: list[dict[str, Any]] = []
    for bar in market_bars:
        day = str(bar.get("day") or "")
        if not day:
            continue
        close = float(bar.get("close") or 0.0)
        tr = float(bar.get("tr") or 0.0)
        tr_pct = (tr / close * 100.0) if close > 0 else None
        cash_info = cash_by_day.get(day)
        cash_delta = cash_info["cash_delta_usdt"] if cash_info else None
        sod_cash = cash_info["sod_cash"] if cash_info else None
        cash_delta_pct = None
        if cash_info and sod_cash is not None and float(sod_cash) > 0 and cash_delta is not None:
            cash_delta_pct = float(cash_delta) / float(sod_cash) * 100.0
        eff = None
        if (
            cash_delta_pct is not None
            and tr_pct is not None
            and abs(float(tr_pct)) > 1e-12
        ):
            eff = float(cash_delta_pct) / float(tr_pct)
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
