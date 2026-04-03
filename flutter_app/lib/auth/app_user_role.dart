/// 与后端 `users.role` 一致：customer / trader / admin
enum AppUserRole {
  customer,
  trader,
  admin,
  unknown;

  static AppUserRole fromApi(String? s) {
    switch ((s ?? '').trim().toLowerCase()) {
      case 'customer':
        return AppUserRole.customer;
      case 'trader':
        return AppUserRole.trader;
      case 'admin':
        return AppUserRole.admin;
      default:
        return AppUserRole.trader;
    }
  }

  String get apiValue {
    switch (this) {
      case AppUserRole.customer:
        return 'customer';
      case AppUserRole.trader:
        return 'trader';
      case AppUserRole.admin:
        return 'admin';
      case AppUserRole.unknown:
        return 'trader';
    }
  }

  /// Web 仪表盘（全局资金与盈亏概览，无启停按钮）
  bool get canViewGlobalDashboard =>
      this == AppUserRole.customer ||
      this == AppUserRole.trader ||
      this == AppUserRole.admin;

  /// Web 策略启动（多账户卡片启停/重启，原「仪表盘」实现）
  bool get canViewStrategyStart =>
      this == AppUserRole.trader || this == AppUserRole.admin;

  /// 策略启停（仅交易员，不含管理员）
  bool get canUseStrategyControl => this == AppUserRole.trader;

  /// 用户与角色管理
  bool get canManageUsers => this == AppUserRole.admin;

  /// Web 侧栏「账户收益与详情」「策略能效评估」等（客户仅能看到已绑定账户，由接口过滤）
  bool get canViewStrategyPerformance =>
      this == AppUserRole.customer ||
      this == AppUserRole.trader ||
      this == AppUserRole.admin;

  static String label(AppUserRole r) {
    switch (r) {
      case AppUserRole.customer:
        return '客户';
      case AppUserRole.trader:
        return '交易员';
      case AppUserRole.admin:
        return '管理员';
      case AppUserRole.unknown:
        return '未知';
    }
  }
}
