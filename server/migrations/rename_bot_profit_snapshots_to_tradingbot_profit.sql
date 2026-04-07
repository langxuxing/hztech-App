-- 盈利快照表历史迁移：bot_profit_snapshots -> tradingbot_profit_snapshots（中间曾用名 tradingbot_profit）
-- 说明：应用启动时 db.init_db() / pg_run_init() 已执行完整迁移，见 _migrate_bot_profit_tables_to_tradingbot_profit_snapshots。
-- 手工时请先确认目标表名，再执行（二选一链路）：

-- SQLite:
-- ALTER TABLE bot_profit_snapshots RENAME TO tradingbot_profit_snapshots;
-- 或从中间名：ALTER TABLE tradingbot_profit RENAME TO tradingbot_profit_snapshots;

-- PostgreSQL:
-- ALTER TABLE bot_profit_snapshots RENAME TO tradingbot_profit_snapshots;
