-- 历史仓位（OKX positions-history 定时入库）；与 db.init_db 中定义一致，供已存在库补建表
CREATE TABLE IF NOT EXISTS account_positions_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    okx_pos_id TEXT NOT NULL,
    inst_id TEXT NOT NULL DEFAULT '',
    inst_type TEXT,
    pos_side TEXT,
    mgn_mode TEXT,
    open_avg_px REAL,
    close_avg_px REAL,
    open_max_pos TEXT,
    close_total_pos TEXT,
    pnl REAL,
    realized_pnl REAL,
    fee REAL,
    funding_fee REAL,
    close_type TEXT,
    c_time_ms TEXT,
    u_time_ms TEXT NOT NULL,
    raw_json TEXT NOT NULL,
    synced_at TEXT NOT NULL,
    UNIQUE(account_id, okx_pos_id, u_time_ms)
);
CREATE INDEX IF NOT EXISTS idx_aph_account ON account_positions_history(account_id);
CREATE INDEX IF NOT EXISTS idx_aph_utime ON account_positions_history(u_time_ms);
