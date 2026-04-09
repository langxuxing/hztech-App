-- 删除 LHG Bot（simpleserver-lhg）与 Hztech Bot（simpleserver-hztech）的全部业务数据。
-- 与 baasapi/purge_simpleserver_bots.py 作用一致；执行前请备份数据库。
-- PostgreSQL / SQLite 均适用（无存储过程）。

BEGIN;

DELETE FROM account_daily_performance WHERE account_id IN ('simpleserver-lhg', 'simpleserver-hztech');
DELETE FROM account_balance_snapshots WHERE account_id IN ('simpleserver-lhg', 'simpleserver-hztech');
DELETE FROM account_open_positions_snapshots WHERE account_id IN ('simpleserver-lhg', 'simpleserver-hztech');
DELETE FROM account_month_balance_baseline WHERE account_id IN ('simpleserver-lhg', 'simpleserver-hztech');
DELETE FROM account_positions_history WHERE account_id IN ('simpleserver-lhg', 'simpleserver-hztech');
DELETE FROM account_season WHERE account_id IN ('simpleserver-lhg', 'simpleserver-hztech');
DELETE FROM tradingbot_mgr WHERE account_id IN ('simpleserver-lhg', 'simpleserver-hztech');
DELETE FROM strategy_events WHERE bot_id IN ('simpleserver-lhg', 'simpleserver-hztech');
DELETE FROM account_list WHERE account_id IN ('simpleserver-lhg', 'simpleserver-hztech');

COMMIT;
