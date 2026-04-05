-- 用户角色：customer（客户）/ trader（交易员）/ admin（管理员）/ strategy_analyst（策略分析师）
-- linked_account_ids：JSON 数组字符串，仅 customer 使用，列出可访问的 account_id / tradingbot_id
ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'trader';
ALTER TABLE users ADD COLUMN linked_account_ids TEXT;
