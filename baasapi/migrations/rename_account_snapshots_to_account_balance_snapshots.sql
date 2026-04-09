-- 手动迁移：仅当数据库仍为旧表名 account_snapshots、且尚未存在 account_balance_snapshots 时执行一次。
-- 若重命名后的表仍含列 profit_amount/profit_percent，请再执行 rename_account_balance_snapshots_profit_to_equity.sql（或由新版应用 init_db 自动迁移）。
-- 正常启动服务端时 db.init_db() 会自动 RENAME，一般无需手工执行。
--
-- 示例：
--   sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/rename_account_snapshots_to_account_balance_snapshots.sql"

BEGIN;
ALTER TABLE account_snapshots RENAME TO account_balance_snapshots;
COMMIT;
