-- AccountMgr：账户列表（与 Account_List.json 同步）、定时快照、月初权益（与 db.init_db 中定义一致，供已存在库补建表）
CREATE TABLE IF NOT EXISTS account_list (
    account_id TEXT PRIMARY KEY,
    account_name TEXT,
    exchange_account TEXT,
    symbol TEXT,
    initial_capital REAL NOT NULL DEFAULT 0,
    trading_strategy TEXT,
    account_key_file TEXT,
    script_file TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS account_balance_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    snapshot_at TEXT NOT NULL,
    cash_balance REAL NOT NULL DEFAULT 0,
    equity_usdt REAL NOT NULL DEFAULT 0,
    equity_profit_amount REAL NOT NULL DEFAULT 0,
    equity_profit_percent REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_account ON account_balance_snapshots(account_id);
CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_at ON account_balance_snapshots(snapshot_at);
CREATE TABLE IF NOT EXISTS account_month_balance_baseline (
    account_id TEXT NOT NULL,
    year_month TEXT NOT NULL,
    initial_equity REAL NOT NULL,
    initial_balance REAL,
    recorded_at TEXT NOT NULL,
    PRIMARY KEY (account_id, year_month)
);
