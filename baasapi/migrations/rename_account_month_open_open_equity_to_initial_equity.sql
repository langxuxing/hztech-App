-- account_month_balance_baseline：月初权益列统一为 initial_equity（与 db.init_db 中迁移一致；已改名可跳过）
-- 表重命名见 rename_account_month_open_to_balance_baseline.sql
-- PostgreSQL：在目标 schema 的 search_path 下执行
ALTER TABLE account_month_balance_baseline RENAME COLUMN open_equity TO initial_equity;
-- 若曾误拼为 open_equlity（equity 拼错）：
-- ALTER TABLE account_month_balance_baseline RENAME COLUMN open_equlity TO initial_equity;
