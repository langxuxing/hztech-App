-- account_month_balance_baseline.open_equity → initial_equity（与 db.init_db 中迁移一致；已改名可跳过）
-- 表重命名见 rename_account_month_open_to_balance_baseline.sql
-- PostgreSQL：在目标 schema 的 search_path 下执行
ALTER TABLE account_month_balance_baseline RENAME COLUMN open_equity TO initial_equity;
