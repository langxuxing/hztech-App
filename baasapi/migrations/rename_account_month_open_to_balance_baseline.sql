-- 表名：account_month_open → account_month_balance_baseline（与 db.init_db 启动迁移一致）
-- PostgreSQL：在目标 schema 的 search_path 下执行；若新表已存在则勿重复执行
ALTER TABLE account_month_open RENAME TO account_month_balance_baseline;

-- SQLite（仅当仍使用旧表名时）:
-- ALTER TABLE account_month_open RENAME TO account_month_balance_baseline;
