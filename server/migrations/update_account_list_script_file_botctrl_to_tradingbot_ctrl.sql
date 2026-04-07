-- 数据迁移：accounts 目录下 botctrl 已重命名为 tradingbot_ctrl，同步更新 account_list.script_file。
-- 若 JSON 已更新且会执行 sync_account_list_from_json，可不必执行；仅当库中仍存旧路径时使用。
--
-- SQLite：
--   sqlite3 server/sqlite/tradingbots.db ".read server/migrations/update_account_list_script_file_botctrl_to_tradingbot_ctrl.sql"

UPDATE account_list
SET script_file = REPLACE(script_file, 'botctrl/', 'tradingbot_ctrl/')
WHERE script_file LIKE 'botctrl/%';
