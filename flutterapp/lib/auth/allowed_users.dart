/// 允许登录的用户（仅用于客户端校验，生产环境建议改为服务端鉴权）
const Map<String, String> allowedUsers = {
  'Admin': 'hz@2026',
  'lhg': 'Lhg@2026',
};

bool validateUser(String username, String password) {
  final user = username.trim();
  final pass = password.trim();
  if (user.isEmpty || pass.isEmpty) return false;
  return allowedUsers[user] == pass;
}
