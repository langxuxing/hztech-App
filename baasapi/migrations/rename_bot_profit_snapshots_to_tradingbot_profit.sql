-- 盈利快照表历史迁移：bot_profit_snapshots -> tradingbot_profit_snapshots（中间曾用名 tradingbot_profit）
-- 历史归档：表现已废弃；新代码在 init 时 DROP 上述表名，见 drop_tradingbot_profit_snapshots.sql。
-- 手工时请先确认目标表名，再执行（二选一链路）：

-- SQLite:
-- ALTER TABLE bot_profit_snapshots RENAME TO tradingbot_profit_snapshots;
-- 或从中间名：ALTER TABLE tradingbot_profit RENAME TO tradingbot_profit_snapshots;

-- PostgreSQL:
-- ALTER TABLE bot_profit_snapshots RENAME TO tradingbot_profit_snapshots;
