-- 添加 lhg 用户（密码与 admin 一致：123）。仅当 username 不存在时插入。
INSERT OR IGNORE INTO users (username, password_hash) VALUES (
  'lhg',
  'a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3'
);
