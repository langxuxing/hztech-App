-- account_season（PostgreSQL 手工建表 / 对照）
-- 与 baasapi/db_backend.py 中 PG_INIT_STATEMENTS 片段一致；修改时请同步 db.py 内 SQLite init_db() 与 migrations/add_bot_seasons.sql。
-- 应用启动时由 pg_run_init() 执行等价 CREATE IF NOT EXISTS；本文件供 psql 手工执行或文档对照。
-- 列语义：initial_equity/final_equity=权益；initial_balance/final_balance=USDT 资产余额（cashBal）。
-- 旧 SQLite/PG 库列名迁移：rename_account_season_cash_columns_to_balance.sql 说明，或由 init_db 中 _ensure_account_season_equity_balance_column_names 自动处理。

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
