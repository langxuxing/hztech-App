-- account_balance_snapshots：profit_amount / profit_percent → equity_profit_amount / equity_profit_percent
-- 应用启动时 SQLite init_db / PostgreSQL 已通过 _ensure_account_balance_snapshots_equity_profit_column_rename 执行；本文件供手工执行。
--
-- SQLite 3.25+：
--   sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/rename_account_balance_snapshots_profit_to_equity.sql"
--
-- PostgreSQL：
--   ALTER TABLE account_balance_snapshots RENAME COLUMN profit_amount TO equity_profit_amount;
--   ALTER TABLE account_balance_snapshots RENAME COLUMN profit_percent TO equity_profit_percent;

ALTER TABLE account_balance_snapshots RENAME COLUMN profit_amount TO equity_profit_amount;
ALTER TABLE account_balance_snapshots RENAME COLUMN profit_percent TO equity_profit_percent;
