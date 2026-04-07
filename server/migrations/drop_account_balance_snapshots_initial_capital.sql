-- 去掉 account_balance_snapshots.initial_capital（本金以 account_list 为准）。
-- SQLite 3.35+：
--   sqlite3 server/sqlite/tradingbots.db ".read server/migrations/drop_account_balance_snapshots_initial_capital.sql"
-- PostgreSQL（列已无时忽略报错）：
--   ALTER TABLE account_balance_snapshots DROP COLUMN IF EXISTS initial_capital;

ALTER TABLE account_balance_snapshots DROP COLUMN initial_capital;
