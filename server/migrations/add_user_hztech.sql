-- 添加 hztech 用户（密码：Hz@2026）。仅当 username 不存在时插入。
INSERT OR IGNORE INTO users (username, password_hash) VALUES (
  'hztech',
  '213f3a6e6d4b5052e28e5b8e8b2b1e8f7406044ca9619f967eca346573a8c736'
);
