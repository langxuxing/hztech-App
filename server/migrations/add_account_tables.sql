-- AccountMgr：账户元数据、定时快照、月初权益（与 db.init_db 中定义一致，供已存在库补建表）
CREATE TABLE IF NOT EXISTS account_meta (
    account_id TEXT PRIMARY KEY,
    initial_capital REAL NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS account_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    snapshot_at TEXT NOT NULL,
    cash_balance REAL NOT NULL DEFAULT 0,
    equity_usdt REAL NOT NULL DEFAULT 0,
    initial_capital REAL NOT NULL DEFAULT 0,
    profit_amount REAL NOT NULL DEFAULT 0,
    profit_percent REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_account_snapshots_account ON account_snapshots(account_id);
CREATE INDEX IF NOT EXISTS idx_account_snapshots_at ON account_snapshots(snapshot_at);
CREATE TABLE IF NOT EXISTS account_month_open (
    account_id TEXT NOT NULL,
    year_month TEXT NOT NULL,
    open_equity REAL NOT NULL,
    recorded_at TEXT NOT NULL,
    PRIMARY KEY (account_id, year_month)
);
