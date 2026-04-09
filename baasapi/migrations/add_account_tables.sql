-- AccountMgr：账户列表（与 Account_List.json 同步）、定时快照、月初基准、赛季表（与 db.py init_db / db_backend.PG_INIT_STATEMENTS 一致，供已存在库补建表）
-- 历史表名/列名迁移见：rename_account_month_open_to_balance_baseline.sql、rename_open_cash_add_daily_perf_changes.sql、rename_account_month_open_open_equity_to_initial_equity.sql
-- account_season 列：initial_equity/final_equity=权益；initial_balance/final_balance=USDT 资产余额（cashBal）。旧列名迁移见 rename_account_season_cash_columns_to_balance.sql
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
    available_margin REAL NOT NULL DEFAULT 0,
    used_margin REAL NOT NULL DEFAULT 0,
    equity_usdt REAL NOT NULL DEFAULT 0,
    equity_profit_amount REAL NOT NULL DEFAULT 0,
    equity_profit_percent REAL NOT NULL DEFAULT 0,
    balance_profit_amount REAL NOT NULL DEFAULT 0,
    balance_profit_percent REAL NOT NULL DEFAULT 0,
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
CREATE TABLE IF NOT EXISTS account_season (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    stopped_at TEXT,
    initial_equity REAL NOT NULL DEFAULT 0,
    initial_balance REAL,
    final_equity REAL,
    final_balance REAL,
    profit_amount REAL,
    profit_percent REAL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id);
CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at);
