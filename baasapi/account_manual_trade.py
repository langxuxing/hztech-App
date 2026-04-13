# -*- coding: utf-8 -*-
"""
Web「账号下单」后端：交易员/管理员对单账户执行市价开平、多空平衡、可选 ATR×0.1 限价止盈。
与 exchange.okx 的私有 trade/order 对齐；ATR 仅依赖日线 K 线（与 strategy_efficiency 一致）。
"""
from __future__ import annotations

import logging
import math
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


def _inst_from_account_row(
    row: dict[str, Any] | None, inst_id_override: str
) -> str:
    raw = (inst_id_override or "").strip()
    if raw:
        return raw
    if not row:
        return ""
    sym = str(row.get("symbol") or "").strip()
    return sym


def latest_atr14_for_inst(
    db_mod: Any,
    okx_mod: Any,
    strategy_efficiency_mod: Any,
    inst_id: str,
    *,
    days: int = 60,
) -> float | None:
    """最近一根有值的日线 Wilder ATR(14)（仅依赖 K 线）。"""
    want = (inst_id or "").strip()
    if not want:
        return None
    try:
        dlim = max(14, min(120, int(days)))
    except (TypeError, ValueError):
        dlim = 60
    bars, m_err = strategy_efficiency_mod.load_market_bars_for_efficiency(
        db_mod, okx_mod, want, dlim
    )
    if m_err or not bars:
        return None
    bars_asc = sorted(bars, key=lambda x: str(x.get("day") or ""))
    atr_map = strategy_efficiency_mod.compute_atr14_wilder_by_day(bars_asc)
    for b in reversed(bars_asc):
        d = str(b.get("day") or "").strip()
        if not d:
            continue
        v = atr_map.get(d)
        if v is not None:
            return float(v)
    return None


def long_short_contracts_for_inst(
    positions: list[dict[str, Any]],
    inst_id: str,
) -> tuple[float, float]:
    """同一 instId 下多、空腿张数（绝对值之和）。"""
    want = (inst_id or "").strip()
    lo = sh = 0.0
    for p in positions:
        if not isinstance(p, dict):
            continue
        if (p.get("inst_id") or "").strip() != want:
            continue
        ps = (p.get("pos_side") or "").strip().lower()
        ab = abs(float(p.get("pos") or 0.0))
        if ab <= 0:
            continue
        if ps == "long":
            lo += ab
        elif ps == "short":
            sh += ab
    return lo, sh


def run_manual_trade_op(
    *,
    op: str,
    account_id: str,
    body: dict[str, Any],
    account_mgr: Any,
    okx_mod: Any,
    db_mod: Any,
    strategy_efficiency_mod: Any,
) -> tuple[dict[str, Any], int]:
    """
    执行手工交易。调用方已校验 trader/admin 与 account 存在。
    body: inst_id?, sz, auto_tp, limit_px（限价开仓）, ord_type（market|limit）
    """
    aid = (account_id or "").strip()
    op_s = (op or "").strip().lower()
    steps: list[dict[str, Any]] = []
    warnings: list[str] = []

    def add_step(name: str, ok: bool, detail: str) -> None:
        steps.append({"name": name, "ok": ok, "detail": detail})

    row = account_mgr.account_list_row_by_id(aid)
    if not row:
        return (
            {"success": False, "message": "未找到账户", "bot_id": aid, "steps": []},
            404,
        )
    dis = account_mgr.okx_account_disabled_exchange_reason(aid)
    if dis:
        return (
            {
                "success": False,
                "message": dis,
                "bot_id": aid,
                "steps": [],
            },
            400,
        )
    inst_override = str(body.get("inst_id") or "").strip()
    sym_src = _inst_from_account_row(row, inst_override)
    inst_id = okx_mod.okx_normalize_swap_inst_id(sym_src)
    if not inst_id.upper().endswith("-SWAP"):
        return (
            {
                "success": False,
                "message": "无法解析永续 instId，请传 inst_id 或配置 Account_List symbol",
                "bot_id": aid,
                "steps": [],
            },
            400,
        )
    path: Path | None = account_mgr.resolve_okx_config_path(aid)
    if path is None or not path.is_file():
        return (
            {
                "success": False,
                "message": "未找到 OKX 密钥文件",
                "bot_id": aid,
                "inst_id": inst_id,
                "steps": [],
            },
            400,
        )

    inst_row, inst_err = okx_mod.okx_public_swap_instrument(inst_id)
    if inst_err or not inst_row:
        return (
            {
                "success": False,
                "message": inst_err or "无法读取合约元数据",
                "bot_id": aid,
                "inst_id": inst_id,
                "steps": [],
            },
            502,
        )
    try:
        lot_sz = float(inst_row.get("lotSz") or 1)
    except (TypeError, ValueError):
        lot_sz = 1.0
    try:
        min_sz = float(inst_row.get("minSz") or lot_sz)
    except (TypeError, ValueError):
        min_sz = lot_sz
    try:
        tick_sz = float(inst_row.get("tickSz") or "0.00000001")
    except (TypeError, ValueError):
        tick_sz = 1e-8

    positions, pos_err = okx_mod.okx_fetch_positions(config_path=path)
    if pos_err:
        add_step("fetch_positions", False, pos_err)
        return (
            {
                "success": False,
                "message": pos_err,
                "bot_id": aid,
                "inst_id": inst_id,
                "steps": steps,
            },
            502,
        )
    lo_sz, sh_sz = long_short_contracts_for_inst(positions, inst_id)

    auto_tp = bool(body.get("auto_tp"))
    ord_type = str(body.get("ord_type") or "market").strip().lower()
    if ord_type not in ("market", "limit"):
        return (
            {
                "success": False,
                "message": "ord_type 仅支持 market 或 limit",
                "bot_id": aid,
            },
            400,
        )
    limit_px_raw = body.get("limit_px")

    def _parse_sz_field() -> tuple[float | None, str | None]:
        raw = body.get("sz")
        if raw is None or raw == "":
            return None, None
        try:
            return float(raw), None
        except (TypeError, ValueError):
            return None, "sz 无效"

    def _maybe_auto_tp(pos_side: str, tp_sz: str) -> None:
        if not auto_tp:
            return
        atr_v = latest_atr14_for_inst(
            db_mod, okx_mod, strategy_efficiency_mod, inst_id
        )
        if atr_v is None or atr_v <= 0:
            warnings.append("日线 ATR(14) 暂无值，已跳过止盈单")
            return
        tk = okx_mod.okx_fetch_ticker(inst_id)
        mk = float(tk) if tk is not None and math.isfinite(float(tk)) else 0.0
        if mk <= 0:
            for p in positions:
                if (p.get("inst_id") or "").strip() != inst_id:
                    continue
                mp = float(p.get("mark_px") or 0.0)
                if mp > 0:
                    mk = mp
                    break
        if mk <= 0:
            warnings.append("无法取得现价，已跳过止盈单")
            return
        dist = 0.1 * float(atr_v)
        if pos_side == "long":
            tp_px = mk + dist
            side = "sell"
        else:
            tp_px = mk - dist
            side = "buy"
        px_s = okx_mod.okx_format_px_str(tp_px, tick_sz)
        res, err = okx_mod.okx_place_swap_order(
            path,
            inst_id=inst_id,
            side=side,
            pos_side=pos_side,
            ord_type="limit",
            sz=tp_sz,
            reduce_only=True,
            px=px_s,
        )
        if err or not res:
            add_step(f"tp_limit_{pos_side}", False, err or "unknown")
            return
        add_step(
            f"tp_limit_{pos_side}",
            True,
            f"ord_id={res.get('ord_id') or ''} px={px_s} sz={tp_sz}",
        )

    def _do_market_or_limit(
        *,
        name: str,
        side: str,
        pos_side: str,
        reduce_only: bool,
        sz_str: str,
    ) -> tuple[bool, str]:
        px_arg: str | None = None
        ot = ord_type
        if ot == "limit" and not reduce_only:
            if limit_px_raw is None or str(limit_px_raw).strip() == "":
                return False, "限价开仓须传 limit_px"
            try:
                lpx = float(limit_px_raw)
            except (TypeError, ValueError):
                return False, "limit_px 无效"
            px_arg = okx_mod.okx_format_px_str(lpx, tick_sz)
        res, err = okx_mod.okx_place_swap_order(
            path,
            inst_id=inst_id,
            side=side,
            pos_side=pos_side,
            ord_type=ot,
            sz=sz_str,
            reduce_only=reduce_only,
            px=px_arg,
        )
        if err or not res:
            add_step(name, False, err or "unknown")
            return False, err or "order failed"
        add_step(name, True, f"ord_id={res.get('ord_id') or ''}")
        return True, ""

    # ----- op 分支 -----
    if op_s in ("open_long", "open_short"):
        sz_f, sz_bad = _parse_sz_field()
        if sz_bad:
            return (
                {
                    "success": False,
                    "message": sz_bad,
                    "bot_id": aid,
                    "steps": steps,
                },
                400,
            )
        if sz_f is None or sz_f <= 0:
            return (
                {
                    "success": False,
                    "message": "开仓须传正数 sz",
                    "bot_id": aid,
                    "steps": steps,
                },
                400,
            )
        sz_str, fmt_err = okx_mod.okx_format_contract_sz_str(
            sz_f, lot_sz, min_sz
        )
        if fmt_err or not sz_str:
            return (
                {
                    "success": False,
                    "message": fmt_err or "sz 格式化失败",
                    "bot_id": aid,
                },
                400,
            )
        if op_s == "open_long":
            ok, _ = _do_market_or_limit(
                name="open_long",
                side="buy",
                pos_side="long",
                reduce_only=False,
                sz_str=sz_str,
            )
            if ok and auto_tp:
                _maybe_auto_tp("long", sz_str)
        else:
            ok, _ = _do_market_or_limit(
                name="open_short",
                side="sell",
                pos_side="short",
                reduce_only=False,
                sz_str=sz_str,
            )
            if ok and auto_tp:
                _maybe_auto_tp("short", sz_str)
        ok_all = all(s.get("ok") for s in steps) if steps else False
        return (
            {
                "success": ok_all,
                "message": "" if ok_all else "部分步骤失败",
                "bot_id": aid,
                "inst_id": inst_id,
                "steps": steps,
                "warnings": warnings,
            },
            200 if ok_all else 502,
        )

    if op_s in ("close_long", "close_short"):
        sz_f, sz_bad = _parse_sz_field()
        if sz_bad:
            return (
                {
                    "success": False,
                    "message": sz_bad,
                    "bot_id": aid,
                    "steps": steps,
                },
                400,
            )
        if op_s == "close_long":
            cap = lo_sz
            side = "sell"
            ps = "long"
        else:
            cap = sh_sz
            side = "buy"
            ps = "short"
        use = cap if sz_f is None else min(float(sz_f), cap)
        if use <= 0:
            return (
                {
                    "success": False,
                    "message": f"无可平{ps}仓位",
                    "bot_id": aid,
                    "inst_id": inst_id,
                    "steps": steps,
                },
                400,
            )
        sz_str, fmt_err = okx_mod.okx_format_contract_sz_str(
            use, lot_sz, min_sz
        )
        if fmt_err or not sz_str:
            return (
                {
                    "success": False,
                    "message": fmt_err or "sz 格式化失败",
                    "bot_id": aid,
                },
                400,
            )
        _do_market_or_limit(
            name=op_s,
            side=side,
            pos_side=ps,
            reduce_only=True,
            sz_str=sz_str,
        )
        ok_all = all(s.get("ok") for s in steps) if steps else False
        return (
            {
                "success": ok_all,
                "message": "" if ok_all else "平仓失败",
                "bot_id": aid,
                "inst_id": inst_id,
                "steps": steps,
                "warnings": warnings,
            },
            200 if ok_all else 502,
        )

    if op_s == "close_all":
        any_ok = True
        if lo_sz > 0:
            sz_str, fmt_err = okx_mod.okx_format_contract_sz_str(
                lo_sz, lot_sz, min_sz
            )
            if fmt_err or not sz_str:
                return (
                    {
                        "success": False,
                        "message": fmt_err or "多仓 sz 错误",
                        "bot_id": aid,
                    },
                    400,
                )
            ok, _ = _do_market_or_limit(
                name="close_long",
                side="sell",
                pos_side="long",
                reduce_only=True,
                sz_str=sz_str,
            )
            any_ok = any_ok and ok
        if sh_sz > 0:
            sz_str, fmt_err = okx_mod.okx_format_contract_sz_str(
                sh_sz, lot_sz, min_sz
            )
            if fmt_err or not sz_str:
                return (
                    {
                        "success": False,
                        "message": fmt_err or "空仓 sz 错误",
                        "bot_id": aid,
                    },
                    400,
                )
            ok, _ = _do_market_or_limit(
                name="close_short",
                side="buy",
                pos_side="short",
                reduce_only=True,
                sz_str=sz_str,
            )
            any_ok = any_ok and ok
        if lo_sz <= 0 and sh_sz <= 0:
            return (
                {
                    "success": True,
                    "message": "当前无持仓",
                    "bot_id": aid,
                    "inst_id": inst_id,
                    "steps": steps,
                    "warnings": warnings,
                },
                200,
            )
        return (
            {
                "success": any_ok,
                "message": "" if any_ok else "部分平仓失败",
                "bot_id": aid,
                "inst_id": inst_id,
                "steps": steps,
                "warnings": warnings,
            },
            200 if any_ok else 502,
        )

    if op_s == "balance_long_short":
        diff = abs(lo_sz - sh_sz)
        if diff <= 0:
            return (
                {
                    "success": True,
                    "message": "多空张数已平衡",
                    "bot_id": aid,
                    "inst_id": inst_id,
                    "steps": steps,
                    "warnings": warnings,
                },
                200,
            )
        sz_str, fmt_err = okx_mod.okx_format_contract_sz_str(
            diff, lot_sz, min_sz
        )
        if fmt_err or not sz_str:
            return (
                {
                    "success": False,
                    "message": fmt_err or f"差额 {diff} 不满足最小下单",
                    "bot_id": aid,
                    "inst_id": inst_id,
                    "long_sz": lo_sz,
                    "short_sz": sh_sz,
                },
                400,
            )
        if lo_sz < sh_sz:
            ok, _ = _do_market_or_limit(
                name="balance_open_long",
                side="buy",
                pos_side="long",
                reduce_only=False,
                sz_str=sz_str,
            )
            if ok and auto_tp:
                _maybe_auto_tp("long", sz_str)
        else:
            ok, _ = _do_market_or_limit(
                name="balance_open_short",
                side="sell",
                pos_side="short",
                reduce_only=False,
                sz_str=sz_str,
            )
            if ok and auto_tp:
                _maybe_auto_tp("short", sz_str)
        ok_all = all(s.get("ok") for s in steps) if steps else False
        return (
            {
                "success": ok_all,
                "message": "" if ok_all else "平衡下单失败",
                "bot_id": aid,
                "inst_id": inst_id,
                "long_sz": lo_sz,
                "short_sz": sh_sz,
                "steps": steps,
                "warnings": warnings,
            },
            200 if ok_all else 502,
        )

    unk = (
        f"未知 op: {op!r}，支持 open_long/open_short/close_long/"
        f"close_short/close_all/balance_long_short"
    )
    return (
        {
            "success": False,
            "message": unk,
            "bot_id": aid,
        },
        400,
    )
