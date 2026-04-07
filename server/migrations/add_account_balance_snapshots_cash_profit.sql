-- account_balance_snapshots：现金（USDT 资产余额）相对期初的收益额与收益率%（与 profit_* 权益口径并列）
-- 应用启动时 SQLite init_db / PostgreSQL 已通过 _ensure_account_balance_snapshots_cash_profit_columns 执行等价变更；本文件供手工对照。

ALTER TABLE account_balance_snapshots ADD COLUMN cash_profit_amount REAL NOT NULL DEFAULT 0;
ALTER TABLE account_balance_snapshots ADD COLUMN cash_profit_percent REAL NOT NULL DEFAULT 0;
