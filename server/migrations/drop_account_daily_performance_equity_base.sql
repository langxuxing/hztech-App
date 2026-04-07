-- 移除 account_daily_performance.equity_base（分母仅用 account_month_open，见 db._month_realized_denom_from_open）
-- SQLite 3.35+：
--   sqlite3 server/sqlite/tradingbots.db ".read server/migrations/drop_account_daily_performance_equity_base.sql"
-- PostgreSQL：
--   ALTER TABLE account_daily_performance DROP COLUMN IF EXISTS equity_base;

ALTER TABLE account_daily_performance DROP COLUMN equity_base;
