-- =============================================================================
-- 推荐：直接执行写入请用 baasapi/seed_alang_sandbox_strategy_efficiency.py（连 DATABASE_URL，与线上一致）。
-- 本文件为 SQLite 手工对照 / 离线备份。
-- 仅覆盖「阿郎测试」账户（account_id = Alang_Sandbox）在策略能效接口中的数据源。
-- 策略能效日线来自 market_daily_bars（全站共用 PEPE-USDT-SWAP 等）——本脚本不修改该表。
-- 本脚本覆盖：
--   - account_daily_performance（北京日历日 day；balance_changed 映射到 UTC K 线日后参与合并）
--   - account_month_balance_baseline（UTC 自然月初资金 USDT / 月初权益，用于收益率分母）
--   - account_balance_snapshots（可选清理近期快照，避免与手工 ADP 混算 sod；详见下方 DELETE）
--
-- 适用：SQLite（与 baasapi/db.py init_db 默认表结构一致）。
-- PostgreSQL：可照同名表执行（把 datetime('now') 改为 now()::text 或 CURRENT_TIMESTAMP），
--            account_daily_performance 可用 ON CONFLICT (account_id, day) DO UPDATE。
--
-- 执行前请自行备份数据库。执行示例：
--   sqlite3 /path/to/tradingbots.db ".read baasapi/migrations/overwrite_alang_sandbox_strategy_efficiency_last_30d.sql"
--
-- 窗口说明：以下为「截至 2026-04-09」共 30 个自然日的演示数据（2026-03-11 .. 2026-04-09）。
-- 若需对齐其它结束日，请整体平移 DELETE 条件与 INSERT 的 day 列表。
-- account_id 与 Account_List.json 中 「阿郎测试」一致。
-- =============================================================================

BEGIN TRANSACTION;

-- 仅删除该账户在重叠窗口内的日绩效（不影响其它 account_id）
DELETE FROM account_daily_performance
WHERE account_id = 'Alang_Sandbox'
  AND day >= '2026-03-01';

-- 仅删除该账户近期快照，避免旧快照与下列 balance_changed 同时参与 sod 递推。
-- 若仍出现 cash_basis=account_snapshots_cash 且数值不符合预期，可改为删除该账户全部快照：
--   DELETE FROM account_balance_snapshots WHERE account_id = 'Alang_Sandbox';
DELETE FROM account_balance_snapshots
WHERE account_id = 'Alang_Sandbox'
  AND snapshot_at >= '2026-03-01T00:00:00.000Z';

-- 覆盖 2026-03 / 2026-04 月初基准（与 Account_List 初始资金 5000 对齐；可按实盘调整）
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
(
    'Alang_Sandbox',
    '2026-03',
    5000,
    5000,
    datetime('now')
),
(
    'Alang_Sandbox',
    '2026-04',
    5000,
    5000,
    datetime('now')
);

-- 日增量 balance_changed（USDT）：对应北京日历日，与接口内 utc_bar_day_for_beijing_ledger_day 对齐后可落到 UTC K 线日键
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-11', 0, 0, 8.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-12', 0, 0, 23.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-13', 0, 0, 39.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-14', 0, 0, 12.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-15', 0, 0, 27.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-16', 0, 0, 43.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-17', 0, 0, 16.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-18', 0, 0, 31.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-19', 0, 0, 47.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-20', 0, 0, 20.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-21', 0, 0, 35.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-22', 0, 0, 16.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-23', 0, 0, 24.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-24', 0, 0, 39.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-25', 0, 0, 20.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-26', 0, 0, 28.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-27', 0, 0, 43.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-28', 0, 0, 24.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-29', 0, 0, 32.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-30', 0, 0, 12.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-03-31', 0, 0, 28.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-04-01', 0, 0, 36.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-04-02', 0, 0, 16.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-04-03', 0, 0, 32.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-04-04', 0, 0, 40.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-04-05', 0, 0, 20.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-04-06', 0, 0, 36.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-04-07', 0, 0, 9.0, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-04-08', 0, 0, 24.5, 'PEPE-USDT-SWAP', datetime('now'));
INSERT OR REPLACE INTO account_daily_performance (account_id, day, net_realized_pnl, close_pos_count, balance_changed, instrument_id, updated_at) VALUES ('Alang_Sandbox', '2026-04-09', 0, 0, 40.0, 'PEPE-USDT-SWAP', datetime('now'));

COMMIT;
