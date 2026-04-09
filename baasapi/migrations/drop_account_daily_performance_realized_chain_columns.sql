-- 移除 account_daily_performance 链式已实现列（与 db._drop_account_daily_performance_realized_chain_columns 一致）
--
--   sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/drop_account_daily_performance_realized_chain_columns.sql"
--   psql "$DATABASE_URL" -f baasapi/migrations/drop_account_daily_performance_realized_chain_columns.sql

-- PostgreSQL
ALTER TABLE account_daily_performance DROP COLUMN IF EXISTS equity_base_realized_chain;
ALTER TABLE account_daily_performance DROP COLUMN IF EXISTS pnl_pct_realized_chain;

-- SQLite 3.35+（若列不存在会报错，请先 PRAGMA table_info 或依赖应用启动时 init_db 内联 DROP）
-- ALTER TABLE account_daily_performance DROP COLUMN equity_base_realized_chain;
-- ALTER TABLE account_daily_performance DROP COLUMN pnl_pct_realized_chain;
