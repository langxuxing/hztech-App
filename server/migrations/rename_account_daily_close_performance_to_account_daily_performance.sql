-- 旧库一次性：account_daily_close_performance -> account_daily_performance
-- 若新表已存在则勿重复执行。示例：
--   sqlite3 server/sqlite/tradingbots.db ".read server/migrations/rename_account_daily_close_performance_to_account_daily_performance.sql"

ALTER TABLE account_daily_close_performance RENAME TO account_daily_performance;
