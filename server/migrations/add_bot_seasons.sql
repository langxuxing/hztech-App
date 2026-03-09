-- 赛季表：记录交易机器人启停时间、初期金额、盈利、盈利率
-- 若已通过 db.init_db() 创建可跳过；仅当数据库为旧版本时执行此脚本。
CREATE TABLE IF NOT EXISTS bot_seasons (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bot_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    stopped_at TEXT,
    initial_balance REAL NOT NULL DEFAULT 0,
    final_balance REAL,
    profit_amount REAL,
    profit_percent REAL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_bot_seasons_bot_id ON bot_seasons(bot_id);
CREATE INDEX IF NOT EXISTS idx_bot_seasons_started ON bot_seasons(started_at);
