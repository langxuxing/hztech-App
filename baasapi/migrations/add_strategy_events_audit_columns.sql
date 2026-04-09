-- strategy_events：审计扩展列（与 init_db 中 _ensure_strategy_events_audit_columns 一致）
-- SQLite 示例：
--   sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/add_strategy_events_audit_columns.sql"
ALTER TABLE strategy_events ADD COLUMN success INTEGER;
ALTER TABLE strategy_events ADD COLUMN detail TEXT;
ALTER TABLE strategy_events ADD COLUMN action_icon TEXT;
