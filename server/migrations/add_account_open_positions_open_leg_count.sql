-- 当前持仓快照：同一合约一行内，多空各计 1 条仓位腿（open_leg_count=1 或 2）
-- SQLite: sqlite3 server/sqlite/tradingbots.db ".read server/migrations/add_account_open_positions_open_leg_count.sql"
ALTER TABLE account_open_positions_snapshots ADD COLUMN open_leg_count INTEGER NOT NULL DEFAULT 0;
UPDATE account_open_positions_snapshots SET open_leg_count =
  (CASE WHEN long_pos_size > 0 THEN 1 ELSE 0 END) +
  (CASE WHEN short_pos_size > 0 THEN 1 ELSE 0 END);
