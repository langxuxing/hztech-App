-- account_daily_performance（PostgreSQL 手工建表 / 对照）
-- 与 baasapi/db_backend.py 中 PG_INIT_STATEMENTS 片段一致；修改时请同步 db.py 内 SQLite init_db() 中的同名表 DDL。
-- 应用启动时由 pg_run_init() 执行等价 CREATE IF NOT EXISTS；本文件供 psql 手工执行或文档对照。
-- 旧库列名迁移：rename_account_daily_performance_legacy_column_names.sql，或由 init_db 中 _rename_account_daily_performance_legacy_columns 自动处理。

CREATE TABLE IF NOT EXISTS account_daily_performance (
    account_id TEXT NOT NULL,
    day TEXT NOT NULL,
    net_realized_pnl DOUBLE PRECISION NOT NULL DEFAULT 0,
    close_pos_count INTEGER NOT NULL DEFAULT 0,
    equlity_changed DOUBLE PRECISION,
    balance_changed DOUBLE PRECISION,
    balance_changed_pct DOUBLE PRECISION,
    pnl_pct DOUBLE PRECISION,
    instrument_id TEXT NOT NULL DEFAULT '',
    market_truevolatility DOUBLE PRECISION,
    efficiency_ratio DOUBLE PRECISION,
    updated_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
    PRIMARY KEY (account_id, day)
);
CREATE INDEX IF NOT EXISTS idx_adp_account ON account_daily_performance(account_id);
CREATE INDEX IF NOT EXISTS idx_adp_day ON account_daily_performance(day);
