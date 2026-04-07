-- 一次性迁移：bot_seasons → account_season，列 bot_id → account_id（SQLite 3.25+）
-- 若已由 server/db.py 的 init_db() 自动执行则无需再跑。
-- 手动执行前请备份数据库。

ALTER TABLE bot_seasons RENAME TO account_season;
ALTER TABLE account_season RENAME COLUMN bot_id TO account_id;
DROP INDEX IF EXISTS idx_bot_seasons_bot_id;
DROP INDEX IF EXISTS idx_bot_seasons_started;
CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id);
CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at);
