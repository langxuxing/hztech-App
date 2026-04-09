-- 旧库一次性：cash_profit_amount / cash_profit_percent → balance_profit_amount / balance_profit_percent
-- 应用启动时由 db._rename_account_balance_snapshots_cash_profit_to_balance_profit 幂等执行；本文件供手工对照。
-- SQLite 示例：
--   sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/rename_account_balance_snapshots_cash_profit_to_balance_profit.sql"

ALTER TABLE account_balance_snapshots RENAME COLUMN cash_profit_amount TO balance_profit_amount;
ALTER TABLE account_balance_snapshots RENAME COLUMN cash_profit_percent TO balance_profit_percent;
