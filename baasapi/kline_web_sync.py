# -*- coding: utf-8 -*-
"""
PEPE 永续（可配置）1 分钟标记价格 K 线：拉取 OKX mark-price-candles，写入 Flutter `web/kline/*.json`。

文件结构兼容 QTrader-web `kline_service._load_from_filesystem`（顶层 `data` 为 K 线数组，元素可为
`[ts,o,h,l,c,vol]` 或含 timestamp/open 字段的字典）。

定时：默认每日 UTC 01:10 执行一轮；可通过环境变量调整。
"""
from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from exchange import okx as _okx

_FILENAME_SAFE = re.compile(r"[^A-Za-z0-9_.-]+")


def kline_output_dir(project_root: Path) -> Path:
    raw = (os.environ.get("HZTECH_KLINE_WEB_DIR") or "").strip()
    if raw:
        return Path(raw)
    return project_root / "flutterapp" / "web" / "kline"


def _default_inst_id() -> str:
    return (os.environ.get("HZTECH_KLINE_INST_ID") or "PEPE-USDT-SWAP").strip()


def _inst_file_tag(inst_id: str) -> str:
    s = inst_id.replace("-", "_").upper()
    return _FILENAME_SAFE.sub("_", s)


def _day_json_path(out_dir: Path, inst_id: str, day: str) -> Path:
    tag = _inst_file_tag(inst_id)
    return out_dir / f"{tag}_1m_mark_{day}.json"


def _list_existing_days(out_dir: Path, inst_id: str) -> set[str]:
    tag = _inst_file_tag(inst_id)
    pat = f"{tag}_1m_mark_*.json"
    out: set[str] = set()
    if not out_dir.is_dir():
        return out
    for p in out_dir.glob(pat):
        m = re.match(
            re.escape(tag) + r"_1m_mark_(\d{4}-\d{2}-\d{2})\.json$",
            p.name,
            re.I,
        )
        if m:
            out.add(m.group(1))
    return out


def _normalize_row(row: list[str]) -> list[float | int] | None:
    if len(row) < 5:
        return None
    try:
        ts = int(float(row[0]))
        o = float(row[1])
        h = float(row[2])
        l = float(row[3])
        c = float(row[4])
        v = float(row[5]) if len(row) > 5 else 0.0
    except (TypeError, ValueError):
        return None
    return [ts, o, h, l, c, v]


def fetch_mark_price_1m_utc_day(
    inst_id: str,
    day_yyyy_mm_dd: str,
    *,
    logger: logging.Logger | None = None,
) -> tuple[list[list[float | int]], str | None]:
    """
    拉取某一 UTC 自然日的 1m 标记价格 K 线，按时间升序。
    先走 mark-price-candles；若整日为空则尝试 history-mark-price-candles。
    """
    log = logger or logging.getLogger(__name__)
    try:
        start_dt = datetime.strptime(day_yyyy_mm_dd, "%Y-%m-%d").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        return [], f"invalid day: {day_yyyy_mm_dd!r}"
    end_dt = start_dt + timedelta(days=1)
    start_ms = int(start_dt.timestamp() * 1000)
    end_ms = int(end_dt.timestamp() * 1000)

    def _paginate() -> dict[int, list[float | int]]:
        """OKX 1m：从新到旧分页。近期用 mark-price-candles；返回空时改用 history-mark-price-candles。"""
        collected: dict[int, list[float | int]] = {}
        after_cursor: int | None = None
        use_history = False
        for round_i in range(400):
            kwargs: dict = {"bar": "1m", "limit": 300, "use_history": use_history}
            if after_cursor is not None:
                kwargs["after_ms"] = after_cursor
            batch, err = _okx.okx_fetch_mark_price_candles(inst_id, **kwargs)
            if err:
                log.debug("kline %s hist=%s err=%s", day_yyyy_mm_dd, use_history, err)
                break
            if not batch and not use_history:
                use_history = True
                batch, err = _okx.okx_fetch_mark_price_candles(
                    inst_id,
                    bar="1m",
                    limit=300,
                    use_history=True,
                    after_ms=after_cursor,
                )
                if err:
                    break
            if not batch:
                break
            ts_vals: list[int] = []
            for row in batch:
                if not isinstance(row, list) or len(row) < 5:
                    continue
                try:
                    ts = int(float(row[0]))
                except (TypeError, ValueError):
                    continue
                ts_vals.append(ts)
                norm = _normalize_row([str(x) for x in row])
                if norm is not None and start_ms <= ts < end_ms:
                    collected[ts] = norm
            if not ts_vals:
                break
            mn = min(ts_vals)
            if mn < start_ms:
                break
            if after_cursor is not None and mn >= after_cursor:
                break
            after_cursor = mn
            time.sleep(0.12)
        return collected

    merged = _paginate()

    ordered = [merged[k] for k in sorted(merged.keys())]
    return ordered, None


def write_day_file(
    out_dir: Path,
    inst_id: str,
    day: str,
    rows: list[list[float | int]],
) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = _day_json_path(out_dir, inst_id, day)
    payload: dict[str, Any] = {
        "inst_id": inst_id,
        "bar": "1m",
        "price_type": "mark",
        "day": day,
        "data": rows,
    }
    path.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    return path


def _missing_days_in_range(
    existing: set[str], last_day: date, lookback_days: int
) -> list[str]:
    start = last_day - timedelta(days=max(1, lookback_days) - 1)
    out: list[str] = []
    cur = start
    while cur <= last_day:
        s = cur.isoformat()
        if s not in existing:
            out.append(s)
        cur += timedelta(days=1)
    return out


def run_mark_1m_sync_cycle(
    project_root: Path,
    logger: logging.Logger | None = None,
) -> dict[str, Any]:
    """
    补全缺失日期的 K 线文件（不超过本轮上限）。last_day 为 UTC 昨日（整日已收盘）。
    """
    log = logger or logging.getLogger(__name__)
    inst = _default_inst_id()
    out_dir = kline_output_dir(project_root)
    lookback = max(7, min(800, int(os.environ.get("HZTECH_KLINE_LOOKBACK_DAYS", "120"))))
    max_raw = int(os.environ.get("HZTECH_KLINE_MAX_DAYS_PER_RUN", "7"))
    if max_raw <= 0:
        return {
            "inst_id": inst,
            "out_dir": str(out_dir),
            "skipped": True,
            "reason": "HZTECH_KLINE_MAX_DAYS_PER_RUN<=0",
        }
    max_days = max(1, min(31, max_raw))

    yesterday = (datetime.now(timezone.utc).date() - timedelta(days=1))
    existing = _list_existing_days(out_dir, inst)
    missing = _missing_days_in_range(existing, yesterday, lookback)[:max_days]

    err_list: list[str] = []
    stats: dict[str, Any] = {
        "inst_id": inst,
        "out_dir": str(out_dir),
        "yesterday": yesterday.isoformat(),
        "attempt_days": len(missing),
        "ok": 0,
        "failed": 0,
        "errors": err_list,
    }

    for d in missing:
        rows, err = fetch_mark_price_1m_utc_day(inst, d, logger=log)
        if err:
            err_list.append(f"{d}: {err}")
            stats["failed"] += 1
            continue
        if len(rows) < 10:
            err_list.append(f"{d}: too_few_rows({len(rows)})")
            stats["failed"] += 1
            continue
        write_day_file(out_dir, inst, d, rows)
        stats["ok"] += 1
        log.info(
            "kline_web_sync: wrote %s 1m mark %s rows=%d",
            inst,
            d,
            len(rows),
        )
    return stats


def _seconds_until_next_utc(hour: int, minute: int) -> float:
    now = datetime.now(timezone.utc)
    target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if target <= now:
        target += timedelta(days=1)
    return (target - now).total_seconds()


def start_kline_nightly_scheduler(
    app_logger: logging.Logger,
    project_root: Path,
) -> None:
    if (os.environ.get("HZTECH_KLINE_SYNC_DISABLED") or "").strip() == "1":
        app_logger.info("⏸️ K线 │ 已关 HZTECH_KLINE_SYNC_DISABLED=1")
        return
    try:
        hour = int((os.environ.get("HZTECH_KLINE_SYNC_HOUR_UTC") or "1").strip())
    except ValueError:
        hour = 1
    try:
        minute = int((os.environ.get("HZTECH_KLINE_SYNC_MINUTE_UTC") or "10").strip())
    except ValueError:
        minute = 10
    hour = max(0, min(23, hour))
    minute = max(0, min(59, minute))

    def _loop() -> None:
        while True:
            delay = _seconds_until_next_utc(hour, minute)
            app_logger.info(
                "🌙 K线 │ 下次 %.0fs │ UTC %02d:%02d",
                delay,
                hour,
                minute,
            )
            time.sleep(delay)
            try:
                st = run_mark_1m_sync_cycle(project_root, app_logger)
                app_logger.info("🌙 K线 │ 本轮 %s", st)
            except Exception as e:
                app_logger.warning("⚠️ K线 │ 本轮异常 │ %s", e, exc_info=True)

    t = threading.Thread(target=_loop, name="kline-nightly", daemon=True)
    t.start()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    root = Path(__file__).resolve().parent.parent
    print(json.dumps(run_mark_1m_sync_cycle(root), ensure_ascii=False, indent=2))
