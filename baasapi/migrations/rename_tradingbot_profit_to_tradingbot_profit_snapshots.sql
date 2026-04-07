-- 盈利快照表重命名：tradingbot_profit -> tradingbot_profit_snapshots
-- 说明：应用启动时 SQLite init_db() / PostgreSQL pg_run_init() 已执行等价迁移。
-- 手工执行前请确认不存在表 tradingbot_profit_snapshots，或已备份数据。

-- SQLite:
-- ALTER TABLE tradingbot_profit RENAME TO tradingbot_profit_snapshots;
-- （可选）重建索引名：
-- DROP INDEX IF EXISTS idx_tradingbot_profit_bot_id;
-- DROP INDEX IF EXISTS idx_tradingbot_profit_snapshot_at;
-- CREATE INDEX IF NOT EXISTS idx_tradingbot_profit_snapshots_bot_id ON tradingbot_profit_snapshots(bot_id);
-- CREATE INDEX IF NOT EXISTS idx_tradingbot_profit_snapshots_snapshot_at ON tradingbot_profit_snapshots(snapshot_at);

-- PostgreSQL:
-- ALTER TABLE tradingbot_profit RENAME TO tradingbot_profit_snapshots;
-- ALTER INDEX IF EXISTS idx_tradingbot_profit_bot_id RENAME TO idx_tradingbot_profit_snapshots_bot_id;
-- ALTER INDEX IF EXISTS idx_tradingbot_profit_snapshot_at RENAME TO idx_tradingbot_profit_snapshots_snapshot_at;
