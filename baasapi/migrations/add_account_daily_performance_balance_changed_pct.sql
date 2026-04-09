-- account_daily_performance：balance_changed 相对当月月初资金%（与重建逻辑一致）
-- 应用启动时由 db._ensure_account_daily_performance_balance_changed_pct 执行；本文件供手工对照。

ALTER TABLE account_daily_performance ADD COLUMN balance_changed_pct REAL;
