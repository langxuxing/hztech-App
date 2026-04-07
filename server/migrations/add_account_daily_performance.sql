-- 平仓按日汇总：净盈亏、权益口径日收益率%、对标标的 TR 的策略能效（与 init_db 中 DDL 一致，供已有库手工执行）
CREATE TABLE IF NOT EXISTS account_daily_performance (
    account_id TEXT NOT NULL,
    day TEXT NOT NULL,
    net_realized_pnl REAL NOT NULL DEFAULT 0,
    close_count INTEGER NOT NULL DEFAULT 0,
    equity_change REAL,
    cash_change REAL,
    pnl_pct REAL,
    equity_base_realized_chain REAL,
    pnl_pct_realized_chain REAL,
    benchmark_inst_id TEXT NOT NULL DEFAULT '',
    market_tr REAL,
    efficiency_ratio REAL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (account_id, day)
);
CREATE INDEX IF NOT EXISTS idx_adp_account ON account_daily_performance(account_id);
CREATE INDEX IF NOT EXISTS idx_adp_day ON account_daily_performance(day);
