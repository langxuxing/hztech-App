-- account_daily_performance：旧列名 → 现行命名（与 baasapi/db.py 中
-- _rename_account_daily_performance_legacy_columns 一致）。
-- 推荐：启动服务时由 init_db 自动执行重命名（幂等）。
-- 手工执行：仅在列仍为旧名时执行对应语句；若已重命名会报错，可忽略。
-- PostgreSQL：先 SET search_path TO <schema>（默认与 HZTECH_POSTGRES_SCHEMA 一致）。
-- 若库内多个 schema 各有一份同名表（如 public 与 flutterapp），需对「仍在使用旧列名」
-- 的那份分别执行，或废弃不用的 schema 下旧表。
--
-- close_count → close_pos_count
-- equity_change → equlity_changed
-- cash_change → balance_changed
-- cash_changed → balance_changed（误命名列；与 cash_change 二选一存在时由 init_db 幂等 RENAME）
-- benchmark_inst_id → instrument_id（未加引号，库中为小写 instrument_id）
-- market_tr → market_truevolatility

ALTER TABLE account_daily_performance RENAME COLUMN close_count TO close_pos_count;
ALTER TABLE account_daily_performance RENAME COLUMN equity_change TO equlity_changed;
ALTER TABLE account_daily_performance RENAME COLUMN cash_change TO balance_changed;
ALTER TABLE account_daily_performance RENAME COLUMN cash_changed TO balance_changed;
ALTER TABLE account_daily_performance RENAME COLUMN benchmark_inst_id TO instrument_id;
ALTER TABLE account_daily_performance RENAME COLUMN market_tr TO market_truevolatility;
