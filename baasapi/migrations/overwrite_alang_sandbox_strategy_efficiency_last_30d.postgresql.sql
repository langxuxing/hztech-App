-- =============================================================================
-- 推荐：直接写入请用 baasapi/seed_alang_sandbox_strategy_efficiency.py（默认 flutterapp schema）。
-- 本文件为 psql 手工执行对照。
-- PostgreSQL 版：仅覆盖 account_id = Alang_Sandbox 的策略能效相关源数据。
-- 不修改 market_daily_bars（全站共用）。
-- 窗口：2026-03-11 .. 2026-04-09（30 天）；与 SQLite 同名脚本一致。
-- 执行：psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f baasapi/migrations/overwrite_alang_sandbox_strategy_efficiency_last_30d.postgresql.sql
-- =============================================================================

BEGIN;

DELETE FROM account_daily_performance
WHERE account_id = 'Alang_Sandbox'
  AND day >= '2026-03-01';

DELETE FROM account_balance_snapshots
WHERE account_id = 'Alang_Sandbox'
  AND snapshot_at >= '2026-03-01T00:00:00.000Z';

DELETE FROM account_month_balance_baseline
WHERE account_id = 'Alang_Sandbox'
  AND year_month IN ('2026-03', '2026-04');

INSERT INTO account_month_balance_baseline (
    account_id,
    year_month,
    initial_equity,
    initial_balance,
    recorded_at
) VALUES
('Alang_Sandbox', '2026-03', 5000, 5000, CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04', 5000, 5000, CURRENT_TIMESTAMP::TEXT)
ON CONFLICT (account_id, year_month) DO UPDATE SET
    initial_equity = EXCLUDED.initial_equity,
    initial_balance = EXCLUDED.initial_balance,
    recorded_at = EXCLUDED.recorded_at;

INSERT INTO account_daily_performance (
    account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at
) VALUES
('Alang_Sandbox', '2026-03-11', 0, 0, 8.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-12', 0, 0, 23.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-13', 0, 0, 39.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-14', 0, 0, 12.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-15', 0, 0, 27.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-16', 0, 0, 43.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-17', 0, 0, 16.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-18', 0, 0, 31.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-19', 0, 0, 47.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-20', 0, 0, 20.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-21', 0, 0, 35.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-22', 0, 0, 16.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-23', 0, 0, 24.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-24', 0, 0, 39.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-25', 0, 0, 20.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-26', 0, 0, 28.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-27', 0, 0, 43.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-28', 0, 0, 24.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-29', 0, 0, 32.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-30', 0, 0, 12.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-03-31', 0, 0, 28.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04-01', 0, 0, 36.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04-02', 0, 0, 16.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04-03', 0, 0, 32.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04-04', 0, 0, 40.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04-05', 0, 0, 20.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04-06', 0, 0, 36.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04-07', 0, 0, 9.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04-08', 0, 0, 24.5, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT),
('Alang_Sandbox', '2026-04-09', 0, 0, 40.0, 'PEPE-USDT-SWAP', CURRENT_TIMESTAMP::TEXT)
ON CONFLICT (account_id, day) DO UPDATE SET
    net_realized_pnl = EXCLUDED.net_realized_pnl,
    close_pos_count = EXCLUDED.close_pos_count,
    balance_changed = EXCLUDED.balance_changed,
    instrument_id = EXCLUDED.instrument_id,
    updated_at = EXCLUDED.updated_at;

COMMIT;
