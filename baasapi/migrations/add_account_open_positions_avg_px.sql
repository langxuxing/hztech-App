-- SQLite：为 account_open_positions_snapshots 增加多/空加权成本（与 OKX avgPx 一致）
--   sqlite3 baasapi/sqlite/tradingbots.db ".read baasapi/migrations/add_account_open_positions_avg_px.sql"
ALTER TABLE account_open_positions_snapshots ADD COLUMN long_avg_px REAL NOT NULL DEFAULT 0;
ALTER TABLE account_open_positions_snapshots ADD COLUMN short_avg_px REAL NOT NULL DEFAULT 0;
