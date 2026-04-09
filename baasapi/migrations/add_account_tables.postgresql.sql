-- account_list、account_balance_snapshots、account_month_balance_baseline、account_season（PostgreSQL 手工建表 / 对照）
-- 与 baasapi/db_backend.py 中 PG_INIT_STATEMENTS 对应片段一致；修改时请同步 db.py 内 SQLite init_db() 中同名表 DDL 与 baasapi/migrations/add_account_tables.sql。
-- account_season 亦可单独对照 add_account_season.postgresql.sql（与本文件末尾 DDL 重复，择一执行即可）。
-- 应用启动时由 pg_run_init() 执行等价 CREATE IF NOT EXISTS；本文件供 psql 手工执行或文档对照。
-- 旧库列名：account_balance_snapshots 的 profit_amount/profit_percent → rename_account_balance_snapshots_profit_to_equity.sql，或由 init_db 自动 RENAME。

CREATE TABLE IF NOT EXISTS account_list (
    account_id TEXT PRIMARY KEY,
    account_name TEXT,
    exchange_account TEXT,
    symbol TEXT,
    initial_capital DOUBLE PRECISION NOT NULL DEFAULT 0,
    trading_strategy TEXT,
    account_key_file TEXT,
    script_file TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
);

CREATE TABLE IF NOT EXISTS account_balance_snapshots (
    id SERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    snapshot_at TEXT NOT NULL,
    cash_balance DOUBLE PRECISION NOT NULL DEFAULT 0,
    available_margin DOUBLE PRECISION NOT NULL DEFAULT 0,
    used_margin DOUBLE PRECISION NOT NULL DEFAULT 0,
    equity_usdt DOUBLE PRECISION NOT NULL DEFAULT 0,
    equity_profit_amount DOUBLE PRECISION NOT NULL DEFAULT 0,
    equity_profit_percent DOUBLE PRECISION NOT NULL DEFAULT 0,
    balance_profit_amount DOUBLE PRECISION NOT NULL DEFAULT 0,
    balance_profit_percent DOUBLE PRECISION NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
);
CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_account ON account_balance_snapshots(account_id);
CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_at ON account_balance_snapshots(snapshot_at);

CREATE TABLE IF NOT EXISTS account_month_balance_baseline (
    account_id TEXT NOT NULL,
    year_month TEXT NOT NULL,
    initial_equity DOUBLE PRECISION NOT NULL,
    initial_balance DOUBLE PRECISION,
    recorded_at TEXT NOT NULL,
    PRIMARY KEY (account_id, year_month)
);

CREATE TABLE IF NOT EXISTS account_season (
    id SERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    stopped_at TEXT,
    initial_equity DOUBLE PRECISION NOT NULL DEFAULT 0,
    initial_balance DOUBLE PRECISION,
    final_equity DOUBLE PRECISION,
    final_balance DOUBLE PRECISION,
    profit_amount DOUBLE PRECISION,
    profit_percent DOUBLE PRECISION,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
);
CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id);
CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at);
