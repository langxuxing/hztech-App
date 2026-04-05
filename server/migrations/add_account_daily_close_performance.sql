-- 平仓按日汇总：净盈亏、权益口径日收益率%、对标标的 TR 的策略能效（与 init_db 中 DDL 一致，供已有库手工执行）
CREATE TABLE IF NOT EXISTS account_daily_close_performance (
    account_id TEXT NOT NULL,
    day TEXT NOT NULL,
    net_realized_pnl REAL NOT NULL DEFAULT 0,
    close_count INTEGER NOT NULL DEFAULT 0,
    equity_base REAL,
    pnl_pct REAL,
    benchmark_inst_id TEXT NOT NULL DEFAULT '',
    market_tr REAL,
    efficiency_ratio REAL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (account_id, day)
);
CREATE INDEX IF NOT EXISTS idx_adcp_account ON account_daily_close_performance(account_id);
CREATE INDEX IF NOT EXISTS idx_adcp_day ON account_daily_close_performance(day);
