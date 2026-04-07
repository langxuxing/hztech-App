# -*- coding: utf-8 -*-
"""account_balance_snapshots 近期 UTC 日缺口检测（供 bills-archive 补全前判断）。"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import db


def test_has_gap_when_no_snapshots():
    aid = "gap-detect-empty"
    db.account_list_upsert(aid, 100.0)
    assert db.account_balance_snapshots_has_gap_in_recent_utc_days(aid, 5) is True


def test_no_gap_when_recent_days_each_have_snapshot():
    aid = "gap-detect-full"
    db.account_list_upsert(aid, 100.0)
    now = datetime.now(timezone.utc).date()
    for i in range(5):
        d = now - timedelta(days=i)
        db.account_snapshot_insert(
            aid,
            f"{d.isoformat()}T12:00:00.000000Z",
            1.0,
            1.0,
            0.0,
            0.0,
            available_margin=1.0,
            used_margin=0.0,
        )
    assert db.account_balance_snapshots_has_gap_in_recent_utc_days(aid, 5) is False
