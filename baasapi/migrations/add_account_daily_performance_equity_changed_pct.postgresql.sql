-- account_daily_performance.equity_changed_pct（与 db._ensure_account_daily_performance_equity_changed_pct 一致）

ALTER TABLE account_daily_performance ADD COLUMN IF NOT EXISTS equity_changed_pct DOUBLE PRECISION;
