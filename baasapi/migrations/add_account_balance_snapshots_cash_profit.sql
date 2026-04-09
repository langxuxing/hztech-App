-- account_balance_snapshots：资产余额相对期初的收益额与收益率%（列名 balance_profit_*；与 equity_profit_* 并列）
-- 旧库列名 cash_profit_* 由 init_db 中 _rename_account_balance_snapshots_cash_profit_to_balance_profit 自动 RENAME。

ALTER TABLE account_balance_snapshots ADD COLUMN balance_profit_amount REAL NOT NULL DEFAULT 0;
ALTER TABLE account_balance_snapshots ADD COLUMN balance_profit_percent REAL NOT NULL DEFAULT 0;
