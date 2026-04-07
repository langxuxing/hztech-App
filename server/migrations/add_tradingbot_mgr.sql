-- 策略启停区间：序号 id、账户、启动时间、结束时间、记录时间
-- 应用启动时 init_db / pg_run_init 会 CREATE IF NOT EXISTS；本文件供手工补表或对照。

-- SQLite:
CREATE TABLE IF NOT EXISTS tradingbot_mgr (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    stopped_at TEXT,
    recorded_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tradingbot_mgr_account ON tradingbot_mgr(account_id);
CREATE INDEX IF NOT EXISTS idx_tradingbot_mgr_started ON tradingbot_mgr(started_at);

-- PostgreSQL:
-- CREATE TABLE IF NOT EXISTS tradingbot_mgr (
--     id SERIAL PRIMARY KEY,
--     account_id TEXT NOT NULL,
--     started_at TEXT NOT NULL,
--     stopped_at TEXT,
--     recorded_at TEXT NOT NULL
-- );
-- CREATE INDEX IF NOT EXISTS idx_tradingbot_mgr_account ON tradingbot_mgr(account_id);
-- CREATE INDEX IF NOT EXISTS idx_tradingbot_mgr_started ON tradingbot_mgr(started_at);
