-- 下线旧 bot 盈利快照表（收益与策略效能已统一 account_balance_snapshots）。
-- 应用启动时 db.init_db() / pg_run_init() 也会 DROP IF EXISTS；此处供仅跑 SQL 的环境手工执行。
-- PostgreSQL / SQLite 均适用。

DROP TABLE IF EXISTS tradingbot_profit_snapshots;
DROP TABLE IF EXISTS tradingbot_profit;
DROP TABLE IF EXISTS bot_profit_snapshots;
