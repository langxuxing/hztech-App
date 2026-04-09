-- 赛季表：账户策略启停周期、权益与 USDT 余额、盈利（表名 account_season；旧名 bot_seasons 已废弃）
-- initial_equity/final_equity=权益；initial_balance/final_balance=USDT 资产余额（OKX cashBal）
-- 应用启动时 init_db / pg_run_init 会 CREATE IF NOT EXISTS；若已通过其创建可跳过。
-- 仅当数据库为旧版本时先执行 rename_bot_seasons_to_account_season.sql，再按需执行本脚本；旧列名迁移见 rename_account_season_cash_columns_to_balance.sql

-- SQLite:
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

-- PostgreSQL:
-- CREATE TABLE IF NOT EXISTS account_season (
--     id SERIAL PRIMARY KEY,
--     account_id TEXT NOT NULL,
--     started_at TEXT NOT NULL,
--     stopped_at TEXT,
--     initial_equity DOUBLE PRECISION NOT NULL DEFAULT 0,
--     initial_balance DOUBLE PRECISION,
--     final_equity DOUBLE PRECISION,
--     final_balance DOUBLE PRECISION,
--     profit_amount DOUBLE PRECISION,
--     profit_percent DOUBLE PRECISION,
--     created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
-- );
-- CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id);
-- CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at);
