-- SQLite / 手工补列：account_open_positions_snapshots 增加 OKX 预估强平价（按张数加权聚合）
-- SQLite: sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/add_account_open_positions_liq_px.sql"
-- PostgreSQL: 见 db._ensure_account_open_positions_liq_columns 或:
--   ALTER TABLE account_open_positions_snapshots ADD COLUMN IF NOT EXISTS long_liq_px DOUBLE PRECISION NOT NULL DEFAULT 0;
--   ALTER TABLE account_open_positions_snapshots ADD COLUMN IF NOT EXISTS short_liq_px DOUBLE PRECISION NOT NULL DEFAULT 0;

ALTER TABLE account_open_positions_snapshots ADD COLUMN long_liq_px REAL NOT NULL DEFAULT 0;
ALTER TABLE account_open_positions_snapshots ADD COLUMN short_liq_px REAL NOT NULL DEFAULT 0;
