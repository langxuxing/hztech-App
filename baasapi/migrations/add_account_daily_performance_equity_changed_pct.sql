-- account_daily_performance：权益相对库内最早快照的变动%（日内临时刷写写入；凌晨完整重算可置 NULL）
-- SQLite:
--   sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/add_account_daily_performance_equity_changed_pct.sql"
-- PostgreSQL: 见 add_account_daily_performance_equity_changed_pct.postgresql.sql

ALTER TABLE account_daily_performance ADD COLUMN equity_changed_pct REAL;
