-- 赛季表：账户策略启停周期、初期权益/现金、盈利（表名 account_season；旧名 bot_seasons 已废弃）
-- 若已通过 db.init_db() 创建可跳过；仅当数据库为旧版本时执行 rename_bot_seasons_to_account_season.sql 后再用此脚本补表。
CREATE TABLE IF NOT EXISTS account_season (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    stopped_at TEXT,
    initial_balance REAL NOT NULL DEFAULT 0,
    initial_cash REAL,
    final_balance REAL,
    final_cash REAL,
    profit_amount REAL,
    profit_percent REAL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id);
CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at);
