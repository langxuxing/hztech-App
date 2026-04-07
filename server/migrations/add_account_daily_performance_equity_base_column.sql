-- 若历史库曾执行「移除 equity_base」的旧版迁移，可手工补回列（与 init_db / _ensure_account_daily_performance_v3 一致）。
-- SQLite 示例：
--   sqlite3 server/sqlite/tradingbots.db ".read server/migrations/add_account_daily_performance_equity_base_column.sql"
-- PostgreSQL：列已存在时忽略报错或先检查 information_schema。

ALTER TABLE account_daily_performance ADD COLUMN equity_base REAL;
