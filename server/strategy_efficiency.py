# -*- coding: utf-8 -*-
"""
按 UTC 自然日汇总账户快照中的现金余额变化，并与 OKX 日线对齐。
输出含：每日波动率%（|高−低|/收盘）、现金收益率%（日增量÷UTC 自然月月初资金×100，无月初则用当日 sod）、
策略能效（日增量 USDT÷(波幅×1e9)）。日线波动数据由 market_daily_bars 全站缓存，各账户共用。

字段名 ``tr`` 存的是当日价格区间 |high−low|（非负），与 OKX 日线合并字段一致；**不是**经典 True Range（需昨收），
也**不是** ATR。经典 ATR(14) 由 ``compute_atr14_wilder_by_day`` 单独从 OHLC 递推（Wilder），供阈值参考。

Account_List 账户的「UTC 自然月月初」资金/权益分母优先用库表 account_month_open（与定时任务一致），无表行时仍可从快照序列推导。
现金日明细优先来自 account_balance_snapshots 的 available_margin（可用保证金；旧行仅误存于 cash_balance）；
旧版 tradingbots.json 机器人用 tradingbot_profit_snapshots（权益 equity_usdt
经 normalize_bot_profit_snapshots_for_efficiency 映射为 cash_balance）。对 K 线有、但当日无快照的日期，
由 fill_cash_by_day_for_market_bars 补齐为「当日无增量」（sod=eod=上一日末现金）；若全程无快照则占位为 0，
以便仍返回结构化行并由 merge 计算现金收益率%与策略能效（增量为 0 时能效为 0）。
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any


def _snapshot_available_margin_cash_basis(r: dict[str, Any]) -> float:
    """账户快照「现金」序列：可用保证金（availEq）；旧行仅误存于 cash_balance。"""
    try:
        am = r.get("available_margin")
        if am is not None and str(am).strip() != "":
            return max(0.0, float(am))
    except (TypeError, ValueError):
        pass
    try:
        return max(0.0, float(r.get("cash_balance") or 0.0))
    except (TypeError, ValueError):
        return 0.0


def normalize_bot_profit_snapshots_for_efficiency(
    bot_profit_rows: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """
    将 tradingbot_profit_snapshots 行转为与 account_balance_snapshots 相同的「按日现金」汇总输入：
    仅保留 snapshot_at + cash_balance（取 equity_usdt，缺省用 current_balance），非负。
    """
    out: list[dict[str, Any]] = []
    for r in bot_profit_rows:
        ts = str(r.get("snapshot_at") or "").strip()
        if not ts:
            continue
        try:
            eq = r.get("equity_usdt")
            if eq is None:
                eq = r.get("current_balance")
            cash = float(eq if eq is not None else 0.0)
        except (TypeError, ValueError):
            cash = 0.0
        cash_v = max(0.0, cash)
        out.append(
            {"snapshot_at": ts, "cash_balance": cash_v, "equity_usdt": cash_v}
        )
    return out


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
    对每个 UTC 日 D：sod_cash / eod_cash 使用可用保证金（available_margin，旧行见 _snapshot_available_margin_cash_basis）。
    按非负处理；日变动 cash_delta_usdt = max(0, eod - sod)，
    不出现负值（仅反映当日余额相对日初的**增加**部分）。
    仅返回当日至少有一条快照的日期。
    """
    points: list[tuple[datetime, float]] = []
    for r in snapshots:
        ts = _parse_snapshot_ts(str(r.get("snapshot_at") or ""))
        if ts is None:
            continue
        cash = _snapshot_available_margin_cash_basis(r)
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


def daily_equity_delta_by_utc_day(snapshots: list[dict[str, Any]]) -> dict[str, dict[str, float]]:
    """
    对每个 UTC 日汇总 equity_usdt（账户快照）或归一化权益（bot 路径与 cash 同源）。
    日增量非负（与 daily_cash_delta_by_utc_day 对称）。
    """
    points: list[tuple[datetime, float]] = []
    for r in snapshots:
        ts = _parse_snapshot_ts(str(r.get("snapshot_at") or ""))
        if ts is None:
            continue
        try:
            eq = r.get("equity_usdt")
            if eq is None:
                eq = r.get("cash_balance")
            v = float(eq if eq is not None else 0.0)
        except (TypeError, ValueError):
            v = 0.0
        v = max(0.0, v)
        points.append((ts, v))
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
        for ts, val in points:
            if ts < day_start:
                sod = val
        first_on_day: float | None = None
        last_on_day: float | None = None
        for ts, val in points:
            if day_start <= ts < day_end:
                if first_on_day is None:
                    first_on_day = val
                last_on_day = val
        if last_on_day is None:
            continue
        if sod is None:
            sod = first_on_day if first_on_day is not None else last_on_day
        eod = last_on_day
        sod = max(0.0, float(sod))
        eod = max(0.0, float(eod))
        delta_raw = eod - sod
        eq_delta = max(0.0, delta_raw)
        out[d] = {
            "sod_equity": sod,
            "eod_equity": eod,
            "equity_delta_usdt": eq_delta,
        }
    return out


def fill_equity_by_day_for_market_bars(
    market_bars: list[dict[str, Any]],
    equity_by_day: dict[str, dict[str, float]],
) -> dict[str, dict[str, float]]:
    """以 K 线 `day` 集合为基准补齐 `equity_by_day`（逻辑同 fill_cash_by_day_for_market_bars）。"""
    days = sorted({str(b.get("day") or "") for b in market_bars if b.get("day")})
    if not days:
        return {k: dict(v) for k, v in equity_by_day.items()}
    out: dict[str, dict[str, float]] = {k: dict(v) for k, v in equity_by_day.items()}
    if not out:
        z = 0.0
        for d in days:
            out[d] = {"sod_equity": z, "eod_equity": z, "equity_delta_usdt": z}
        return out

    first_snap = min(out.keys())
    anchor_pre = float(out[first_snap]["sod_equity"])

    prior_to_window = [x for x in out if x < days[0]]
    if prior_to_window:
        carry = float(out[max(prior_to_window)]["eod_equity"])
    elif days[0] > first_snap:
        carry = float(out[first_snap]["eod_equity"])
        for dd in sorted(x for x in out if first_snap < x < days[0]):
            carry = float(out[dd]["eod_equity"])
    else:
        carry = anchor_pre

    for d in days:
        if d < first_snap:
            out[d] = {
                "sod_equity": anchor_pre,
                "eod_equity": anchor_pre,
                "equity_delta_usdt": 0.0,
            }
            continue
        if d in out:
            carry = float(out[d]["eod_equity"])
            continue
        out[d] = {
            "sod_equity": carry,
            "eod_equity": carry,
            "equity_delta_usdt": 0.0,
        }
    return out


def month_start_equity_by_month_from_snapshots(
    snapshots: list[dict[str, Any]],
) -> dict[str, float]:
    """每个 UTC 自然月 YYYY-MM 的「月初权益」：该月 1 日 00:00 UTC 前最后一笔 equity_usdt（无则取当月首条）。"""
    points: list[tuple[datetime, float]] = []
    for r in snapshots:
        ts = _parse_snapshot_ts(str(r.get("snapshot_at") or ""))
        if ts is None:
            continue
        try:
            eq = r.get("equity_usdt")
            if eq is None:
                eq = r.get("cash_balance")
            v = float(eq if eq is not None else 0.0)
        except (TypeError, ValueError):
            v = 0.0
        v = max(0.0, v)
        points.append((ts, v))
    if not points:
        return {}
    points.sort(key=lambda x: x[0])
    ym_set = {(ts.year, ts.month) for ts, _ in points}
    out: dict[str, float] = {}
    for y, m in sorted(ym_set):
        boundary = datetime(y, m, 1, tzinfo=timezone.utc)
        last_before: float | None = None
        for ts, val in points:
            if ts < boundary:
                last_before = val
        key = f"{y:04d}-{m:02d}"
        if last_before is not None:
            out[key] = max(0.0, float(last_before))
        else:
            for ts, val in points:
                if ts.year == y and ts.month == m:
                    out[key] = max(0.0, float(val))
                    break
    return out


def fill_cash_by_day_for_market_bars(
    market_bars: list[dict[str, Any]],
    cash_by_day: dict[str, dict[str, float]],
) -> dict[str, dict[str, float]]:
    """
    以 K 线 `day` 集合为基准补齐 `cash_by_day`。

    - 已有快照汇总的日期保留原值。
    - 早于首条有快照日的 K 线日：sod=eod=首快照日的 sod，增量 0。
    - 首快照日之后、中间缺日：sod=eod=上一日末余额（由最近一条真实日 eod 传递），增量 0。
    - 无任何快照数据时：全日 sod=eod=0、增量 0（占位）。
    """
    days = sorted({str(b.get("day") or "") for b in market_bars if b.get("day")})
    if not days:
        return {k: dict(v) for k, v in cash_by_day.items()}
    out: dict[str, dict[str, float]] = {k: dict(v) for k, v in cash_by_day.items()}
    if not out:
        z = 0.0
        for d in days:
            out[d] = {"sod_cash": z, "eod_cash": z, "cash_delta_usdt": z}
        return out

    first_snap = min(out.keys())
    anchor_pre = float(out[first_snap]["sod_cash"])

    prior_to_window = [x for x in out if x < days[0]]
    if prior_to_window:
        carry = float(out[max(prior_to_window)]["eod_cash"])
    elif days[0] > first_snap:
        carry = float(out[first_snap]["eod_cash"])
        for dd in sorted(x for x in out if first_snap < x < days[0]):
            carry = float(out[dd]["eod_cash"])
    else:
        carry = anchor_pre

    for d in days:
        if d < first_snap:
            out[d] = {
                "sod_cash": anchor_pre,
                "eod_cash": anchor_pre,
                "cash_delta_usdt": 0.0,
            }
            continue
        if d in out:
            carry = float(out[d]["eod_cash"])
            continue
        out[d] = {
            "sod_cash": carry,
            "eod_cash": carry,
            "cash_delta_usdt": 0.0,
        }
    return out


def month_start_cash_by_month_from_snapshots(
    snapshots: list[dict[str, Any]],
) -> dict[str, float]:
    """
    每个 UTC 自然月 YYYY-MM 对应「月初」资金：
    该月 1 日 00:00 UTC 之前最后一笔快照的可用保证金（与 daily_cash_delta 同源）；
    若该月前无任何快照，则取该月内最早一条快照余额（新户首月）。
    """
    points: list[tuple[datetime, float]] = []
    for r in snapshots:
        ts = _parse_snapshot_ts(str(r.get("snapshot_at") or ""))
        if ts is None:
            continue
        cash = _snapshot_available_margin_cash_basis(r)
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


def close_pnl_efficiency_ratio(net_realized_usdt: float, market_tr: float) -> float | None:
    """
    与 merge_daily_efficiency_rows 中策略能效同一量纲：
    平仓净盈亏(USDT) ÷ (标的日线真实波幅 TR × 1e9)。TR≤0 时返回 None。
    """
    tr = float(market_tr or 0.0)
    if tr <= 1e-18:
        return None
    return float(net_realized_usdt) / (tr * 1e9)


def compute_atr14_wilder_by_day(bars_asc: list[dict[str, Any]]) -> dict[str, float | None]:
    """
    按日历日升序的 OHLC 计算 Wilder ATR(14)。TR 为经典定义（含昨收）。
    不足 14 根 K 线时各日 ATR 为 None；从第 14 根起有值。
    """
    if not bars_asc:
        return {}
    trs: list[float] = []
    prev_close: float | None = None
    for b in bars_asc:
        h = float(b.get("high") or 0.0)
        l = float(b.get("low") or 0.0)
        c = float(b.get("close") or 0.0)
        hl = max(0.0, h - l)
        if prev_close is None:
            tr = hl
        else:
            pc = float(prev_close)
            tr = max(hl, abs(h - pc), abs(l - pc))
        trs.append(tr)
        prev_close = c
    n = len(trs)
    out: dict[str, float | None] = {}
    if n < 14:
        for b in bars_asc:
            d = str(b.get("day") or "")
            if d:
                out[d] = None
        return out
    atr = sum(trs[:14]) / 14.0
    for i in range(13):
        d = str(bars_asc[i].get("day") or "")
        if d:
            out[d] = None
    d13 = str(bars_asc[13].get("day") or "")
    if d13:
        out[d13] = atr
    for i in range(14, n):
        atr = (atr * 13.0 + trs[i]) / 14.0
        di = str(bars_asc[i].get("day") or "")
        if di:
            out[di] = atr
    return out


def merge_daily_efficiency_rows(
    market_bars: list[dict[str, Any]],
    cash_by_day: dict[str, dict[str, float]],
    month_base_by_month: dict[str, float] | None = None,
    *,
    equity_by_day: dict[str, dict[str, float]] | None = None,
    month_equity_base_by_month: dict[str, float] | None = None,
    atr14_by_day: dict[str, float | None] | None = None,
) -> list[dict[str, Any]]:
    """合并日线波动（|高−低|，非负）与现金日增量（非负），并计算 tr_pct、现金收益率%、策略能效；可选权益与 ATR(14)。"""
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

        eq_info = equity_by_day.get(day) if equity_by_day else None
        equity_delta = eq_info["equity_delta_usdt"] if eq_info else None
        sod_equity = eq_info["sod_equity"] if eq_info else None
        month_eq_base: float | None = None
        if month_equity_base_by_month and month_key:
            me = month_equity_base_by_month.get(month_key)
            if me is not None and float(me) > 0:
                month_eq_base = float(me)
        yield_eq_month = month_eq_base is not None
        if month_eq_base is None and eq_info and sod_equity is not None and float(sod_equity) > 0:
            month_eq_base = float(sod_equity)
        equity_delta_pct = None
        month_start_equity_out: float | None = None
        if equity_delta is not None and month_eq_base is not None and month_eq_base > 0:
            equity_delta_pct = float(equity_delta) / month_eq_base * 100.0
            if yield_eq_month:
                month_start_equity_out = month_eq_base
        equity_eff = None
        if equity_delta is not None and tr > 1e-18:
            equity_eff = float(equity_delta) / (float(tr) * 1e9)

        atr14: float | None = None
        if atr14_by_day and day in atr14_by_day:
            av = atr14_by_day[day]
            atr14 = float(av) if av is not None else None
        th01 = th06 = th12 = None
        if atr14 is not None and atr14 > 1e-18:
            th01 = 0.1 * atr14
            th06 = 0.6 * atr14
            th12 = 1.2 * atr14

        row: dict[str, Any] = {
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
        if equity_by_day is not None:
            row["sod_equity"] = sod_equity
            row["eod_equity"] = eq_info["eod_equity"] if eq_info else None
            row["equity_delta_usdt"] = equity_delta
            row["equity_delta_pct"] = equity_delta_pct
            row["month_start_equity"] = month_start_equity_out
            row["equity_efficiency_ratio"] = equity_eff
        if atr14_by_day is not None:
            row["atr14"] = atr14
            row["threshold_0_1_atr_price"] = th01
            row["threshold_0_6_atr_price"] = th06
            row["threshold_1_2_atr_price"] = th12
        rows.append(row)
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
    batch: list[tuple[str, str, float, float, float, float, float]] = []
    for b in bars:
        d = str(b.get("day") or "")
        if not d:
            continue
        batch.append(
            (
                inst_id,
                d,
                float(b.get("open") or 0.0),
                float(b.get("high") or 0.0),
                float(b.get("low") or 0.0),
                float(b.get("close") or 0.0),
                max(0.0, float(b.get("tr") or 0.0)),
            )
        )
    if batch:
        db_mod.market_daily_bars_upsert_many(batch)
    return None


def _upsert_okx_bars(db_mod: Any, inst_id: str, bars: list[dict[str, Any]]) -> None:
    batch: list[tuple[str, str, float, float, float, float, float]] = []
    for b in bars:
        d = str(b.get("day") or "")
        if not d:
            continue
        batch.append(
            (
                inst_id,
                d,
                float(b.get("open") or 0.0),
                float(b.get("high") or 0.0),
                float(b.get("low") or 0.0),
                float(b.get("close") or 0.0),
                max(0.0, float(b.get("tr") or 0.0)),
            )
        )
    if batch:
        db_mod.market_daily_bars_upsert_many(batch)


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
