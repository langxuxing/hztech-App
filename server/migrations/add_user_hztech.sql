-- 添加 hztech 用户（缺省密码：i23321，SHA256）。仅当 username 不存在时插入。
INSERT OR IGNORE INTO users (username, password_hash) VALUES (
  'hztech',
  '4f1e136e8913a8d4748d82e6c401edb30b9dd88e1fac0d63140b23ea259ddf94'
);
