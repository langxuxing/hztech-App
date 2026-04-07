-- OKX 当前持仓聚合快照（与 db.init_db 一致；已存在库可手动执行补表）
--   sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/add_account_open_positions_snapshots.sql"
CREATE TABLE IF NOT EXISTS account_open_positions_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    inst_id TEXT NOT NULL,
    snapshot_at TEXT NOT NULL,
    last_px REAL NOT NULL DEFAULT 0,
    long_pos_size REAL NOT NULL DEFAULT 0,
    short_pos_size REAL NOT NULL DEFAULT 0,
    mark_px REAL NOT NULL DEFAULT 0,
    long_upl REAL NOT NULL DEFAULT 0,
    short_upl REAL NOT NULL DEFAULT 0,
    total_upl REAL NOT NULL DEFAULT 0,
    open_leg_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_aops_account_at ON account_open_positions_snapshots(account_id, snapshot_at);
CREATE INDEX IF NOT EXISTS idx_aops_account_inst ON account_open_positions_snapshots(account_id, inst_id);
