-- 删除已废弃的 key-value 表；JWT 等配置改为仅使用环境变量 JWT_SECRET、JWT_EXP_DAYS。
-- SQLite / PostgreSQL 均适用。
DROP TABLE IF EXISTS config;
