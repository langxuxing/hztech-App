-- 用户资料：全名、手机号（可选；登录仍使用 username）
ALTER TABLE users ADD COLUMN full_name TEXT;
ALTER TABLE users ADD COLUMN phone TEXT;
