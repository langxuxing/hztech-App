-- 已有 account_daily_performance 表时补列：链式已实现权益分母与收益率（与 init_db / _ensure_account_daily_performance_chain_columns 一致）
-- 列已存在时勿重复执行。应用启动时 init_db 会自动补列。
-- SQLite:
--   sqlite3 server/sqlite/tradingbots.db ".read server/migrations/add_account_daily_performance_realized_chain_columns.sql"
-- PostgreSQL（可将 REAL 改为 DOUBLE PRECISION）:
--   psql "$DATABASE_URL" -f server/migrations/add_account_daily_performance_realized_chain_columns.sql

ALTER TABLE account_daily_performance ADD COLUMN equity_base_realized_chain REAL;
ALTER TABLE account_daily_performance ADD COLUMN pnl_pct_realized_chain REAL;
