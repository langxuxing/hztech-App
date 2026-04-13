# -*- coding: utf-8 -*-
"""定时账户同步任务 _job_fetch_account_and_save_snapshots 与 /api/status 结构。"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock

import db
import exchange.okx as okx_mod


def test_job_fetch_account_and_save_snapshots_updates_sync_steps(monkeypatch):
    """不访问 OKX：mock AccountMgr / strategy_efficiency，校验各步骤标记为成功。"""
    import main as m

    monkeypatch.setattr(
        m._account_mgr, "refresh_all_balance_snapshots", MagicMock()
    )
    monkeypatch.setattr(
        m._account_mgr, "refresh_all_positions_history", MagicMock()
    )
    monkeypatch.setattr(
        m._account_mgr, "refresh_all_open_positions_snapshots", MagicMock()
    )
    monkeypatch.setattr(
        m._strategy_efficiency,
        "ensure_shared_market_daily_bars",
        MagicMock(return_value=None),
    )

    m._job_fetch_account_and_save_snapshots()

    snap = m._sync_state_snapshot()
    assert snap.get("last_loop_error") is None
    steps = snap.get("steps") or {}
    assert steps.get("balance_snapshots", {}).get("ok") is True
    assert steps.get("positions_history", {}).get("ok") is True
    assert steps.get("open_positions_snapshots", {}).get("ok") is True
    assert snap.get("last_run_completed_at")


def test_api_status_includes_open_positions_sync_step(client, auth_headers):
    """已登录 /api/status 含 open_positions_snapshots 步骤键。"""
    r = client.get("/api/status", headers=auth_headers)
    assert r.status_code == 200
    data = r.get_json()
    assert data.get("success") is True
    sync = data.get("sync") or {}
    steps = sync.get("steps") or {}
    assert "open_positions_snapshots" in steps
    doc = data.get("sync_documentation") or ""
    assert "account_open_positions_snapshots" in doc
    assert "account_daily_performance" in doc


def test_api_status_includes_http_request_stats(client, auth_headers):
    """http_request_stats：本进程累计；快照在视图内生成故不含当前 /api/status 这一笔。"""
    client.get("/api/health")
    client.get("/api/health")
    r = client.get("/api/status", headers=auth_headers)
    assert r.status_code == 200
    stats = (r.get_json() or {}).get("http_request_stats") or {}
    assert stats.get("disabled") is False
    assert int(stats.get("total") or 0) >= 2
    top = stats.get("top_endpoints") or []
    by_ep = {x.get("endpoint"): int(x.get("count") or 0) for x in top if isinstance(x, dict)}
    assert by_ep.get("api_health", 0) >= 2
    assert "by_status_class" in stats
    assert stats.get("idle_traffic_hint")


def _utc_yesterday_iso() -> str:
    return (datetime.now(timezone.utc).date() - timedelta(days=1)).isoformat()


def test_e2e_sync_job_writes_balance_and_open_positions_snapshots(
    tmp_path: Path, monkeypatch
):
    """
    不访问真实 OKX：mock 余额/持仓/历史持仓接口，走完整 AccountMgr 逻辑，
    验证 _job_fetch_account_and_save_snapshots 写入 account_balance_snapshots 与
    account_open_positions_snapshots。
    """
    import accounts.AccountMgr as am
    import main as m

    inst = m._DEFAULT_STRATEGY_EFFICIENCY_INST_ID
    db.market_daily_bars_upsert(
        inst, _utc_yesterday_iso(), 1.0, 1.1, 0.9, 1.05, 0.2
    )

    fake_key = tmp_path / "fake_okx.json"
    fake_key.write_text(
        '{"apiKey":"x","secret":"y","passphrase":"z"}', encoding="utf-8"
    )
    aid = "e2e_auto_sync_test_01"

    def fake_iter_okx(*, enabled_only: bool = True):
        return [
            {
                "account_id": aid,
                "exchange_account": "OKX",
                "account_key_file": "fake_okx.json",
                "enabled": True,
                "Initial_capital": 10000.0,
                "symbol": inst,
            }
        ]

    def fake_resolve(account_id: str):
        return fake_key if (account_id or "").strip() == aid else None

    monkeypatch.setattr(am, "iter_okx_accounts", fake_iter_okx)
    monkeypatch.setattr(am, "resolve_okx_config_path", fake_resolve)

    def fake_balance(*_a, **_k):
        return {
            "equity_usdt": 10000.0,
            "total_eq": 10000.0,
            "cash_balance": 8000.0,
            "available_margin": 7500.0,
            "used_margin": 2500.0,
            "avail_eq": 7500.0,
            "upl": -50.0,
        }

    def fake_positions(*_a, **_k):
        return (
            [
                {
                    "inst_id": inst,
                    "pos_side": "long",
                    "pos": 100.0,
                    "upl": -2.5,
                    "mark_px": 1.5,
                    "last_px": 1.48,
                    "avg_px": 1.52,
                }
            ],
            None,
        )

    def fake_positions_hist(*_a, **_k):
        return ([], None)

    monkeypatch.setattr(okx_mod, "okx_fetch_balance", fake_balance)
    monkeypatch.setattr(okx_mod, "okx_fetch_positions", fake_positions)
    monkeypatch.setattr(
        okx_mod, "okx_fetch_positions_history_contracts", fake_positions_hist
    )

    m._job_fetch_account_and_save_snapshots()

    bal = db.account_snapshot_latest_by_account(aid)
    assert bal is not None
    assert abs(float(bal["equity_usdt"]) - 10000.0) < 1e-4
    assert abs(float(bal["cash_balance"]) - 8000.0) < 1e-4
    assert abs(float(bal["available_margin"]) - 7500.0) < 1e-4
    assert abs(float(bal["used_margin"]) - 2500.0) < 1e-4

    pos_rows = db.account_open_positions_snapshots_query_by_account(aid, limit=10)
    assert len(pos_rows) >= 1
    hit = next((r for r in pos_rows if r["inst_id"] == inst), None)
    assert hit is not None
    assert abs(float(hit["long_pos_size"]) - 100.0) < 1e-4
    assert abs(float(hit["long_upl"]) - (-2.5)) < 1e-4
