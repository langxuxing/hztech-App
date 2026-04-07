-- 策略能效：全站共用的 OKX 日线波动（|高−低| 等为 tr），按 inst_id + UTC 日缓存。
CREATE TABLE IF NOT EXISTS market_daily_bars (
    inst_id TEXT NOT NULL,
    day TEXT NOT NULL,
    open REAL NOT NULL,
    high REAL NOT NULL,
    low REAL NOT NULL,
    close REAL NOT NULL,
    tr REAL NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (inst_id, day)
);
CREATE INDEX IF NOT EXISTS idx_market_daily_bars_inst_day ON market_daily_bars(inst_id, day);
