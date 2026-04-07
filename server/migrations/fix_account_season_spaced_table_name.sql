-- 一次性修复：表名误写为 account_season␠（尾部空格）时，重命名为 account_season；列 bot_id → account_id。
-- 若已由 server/db.py 的 init_db() 中 _migrate_account_season_spaced_name_and_bot_id 自动执行则无需再跑。
-- 手动执行前请备份数据库。

-- 若仅有带空格表名、无规范表名：
-- ALTER TABLE "account_season " RENAME TO account_season;

-- 若同时存在空的 account_season 与带空格的旧表（先删空表再改名）：
-- DROP TABLE IF EXISTS account_season;
-- ALTER TABLE "account_season " RENAME TO account_season;

-- ALTER TABLE account_season RENAME COLUMN bot_id TO account_id;
-- CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id);
-- CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at);
