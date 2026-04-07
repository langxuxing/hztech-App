-- 手动迁移：仅当数据库仍为旧表名 account_meta、且尚未存在 account_list 时执行一次。
-- 正常启动服务端时 db.init_db() 会自动完成重命名与补列，一般无需手工执行。
--
-- 示例：
--   sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/rename_account_meta_to_account_list.sql"

BEGIN;
ALTER TABLE account_meta RENAME TO account_list;
ALTER TABLE account_list ADD COLUMN account_name TEXT;
ALTER TABLE account_list ADD COLUMN exchange_account TEXT;
ALTER TABLE account_list ADD COLUMN symbol TEXT;
ALTER TABLE account_list ADD COLUMN trading_strategy TEXT;
ALTER TABLE account_list ADD COLUMN account_key_file TEXT;
ALTER TABLE account_list ADD COLUMN script_file TEXT;
ALTER TABLE account_list ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;
COMMIT;
