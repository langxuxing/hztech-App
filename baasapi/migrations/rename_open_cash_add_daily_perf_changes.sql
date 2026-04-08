-- 一次性迁移（PostgreSQL / SQLite 3.25+ 语法略有差异时请分环境执行）
-- account_month_balance_baseline.open_cash -> initial_balance（旧表名见 rename_account_month_open_to_balance_baseline.sql）
-- account_daily_performance: +equity_change, +cash_change, -equity_base（请先补全链式列若旧库缺失）

-- PostgreSQL:
-- ALTER TABLE account_month_balance_baseline RENAME COLUMN open_cash TO initial_balance;
-- ALTER TABLE account_daily_performance ADD COLUMN IF NOT EXISTS equity_change DOUBLE PRECISION;
-- ALTER TABLE account_daily_performance ADD COLUMN IF NOT EXISTS cash_change DOUBLE PRECISION;
-- ALTER TABLE account_daily_performance DROP COLUMN IF EXISTS equity_base;

-- SQLite（需 3.35+ 才支持 DROP COLUMN）:
-- ALTER TABLE account_month_balance_baseline RENAME COLUMN open_cash TO initial_balance;
-- ALTER TABLE account_daily_performance ADD COLUMN equity_change REAL;
-- ALTER TABLE account_daily_performance ADD COLUMN cash_change REAL;
-- ALTER TABLE account_daily_performance DROP COLUMN equity_base;
