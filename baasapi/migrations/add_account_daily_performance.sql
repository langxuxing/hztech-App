-- 平仓按日汇总（SQLite 手工建表 / 对照）
-- 列：close_pos_count, equlity_changed, balance_changed, balance_changed_pct, instrument_id,
--     market_truevolatility（及 net_realized_pnl, pnl_pct, efficiency_ratio, updated_at）；
--     与 baasapi/db.py 中 init_db() 内联 CREATE 一致。
-- PostgreSQL：使用同目录下 add_account_daily_performance.postgresql.sql（与 db_backend.pg_run_init 一致）。
-- 旧列名迁移：rename_account_daily_performance_legacy_column_names.sql 或启动服务 init_db。
CREATE TABLE IF NOT EXISTS account_daily_performance (
    account_id TEXT NOT NULL,
    day TEXT NOT NULL,
    net_realized_pnl REAL NOT NULL DEFAULT 0,
    close_pos_count INTEGER NOT NULL DEFAULT 0,
    equlity_changed REAL,
    balance_changed REAL,
    balance_changed_pct REAL,
    equity_changed_pct REAL,
    pnl_pct REAL,
    instrument_id TEXT NOT NULL DEFAULT '',
    market_truevolatility REAL,
    efficiency_ratio REAL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (account_id, day)
);
CREATE INDEX IF NOT EXISTS idx_adp_account ON account_daily_performance(account_id);
CREATE INDEX IF NOT EXISTS idx_adp_day ON account_daily_performance(day);
