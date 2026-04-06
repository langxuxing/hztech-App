/// 与后端 `users.role` 一致：customer / trader / admin / strategy_analyst
enum AppUserRole {
  customer,
  trader,
  admin,
  strategyAnalyst,
  unknown;

  static AppUserRole fromApi(String? s) {
    switch ((s ?? '').trim().toLowerCase()) {
      case 'customer':
        return AppUserRole.customer;
      case 'trader':
        return AppUserRole.trader;
      case 'admin':
        return AppUserRole.admin;
      case 'strategy_analyst':
        return AppUserRole.strategyAnalyst;
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
      case AppUserRole.strategyAnalyst:
        return 'strategy_analyst';
      case AppUserRole.unknown:
        return 'trader';
    }
  }

  /// Web 仪表盘（全局资金与盈亏概览，无启停按钮）
  bool get canViewGlobalDashboard =>
      this == AppUserRole.customer ||
      this == AppUserRole.trader ||
      this == AppUserRole.admin ||
      this == AppUserRole.strategyAnalyst;

  /// Web 策略启停（多账户卡片赛季/进程启停与重启）
  bool get canViewStrategyStart =>
      this == AppUserRole.trader || this == AppUserRole.admin;

  /// 策略启停（移动端等）：交易员或管理员
  bool get canUseStrategyControl =>
      this == AppUserRole.trader || this == AppUserRole.admin;

  /// 用户与角色管理（增删改权限）
  bool get canManageUsers => this == AppUserRole.admin;

  /// 已绑定账户的 OKX 密钥 JSON 上传与测连（Web 侧栏「账户配置」）
  bool get canConfigureLinkedOkxKeys => this == AppUserRole.customer;

  /// Web「收网测试」页：交易员、管理员、策略分析师（与后端一致；客户无）
  bool get canViewAutoNettingTest =>
      this == AppUserRole.strategyAnalyst ||
      this == AppUserRole.trader ||
      this == AppUserRole.admin;

  /// Web 侧栏「账户收益与详情」「策略能效评估」等（客户仅能看到已绑定账户，由接口过滤）
  bool get canViewStrategyPerformance =>
      this == AppUserRole.customer ||
      this == AppUserRole.trader ||
      this == AppUserRole.admin ||
      this == AppUserRole.strategyAnalyst;

  static String label(AppUserRole r) {
    switch (r) {
      case AppUserRole.customer:
        return '客户';
      case AppUserRole.trader:
        return '交易员';
      case AppUserRole.admin:
        return '管理员';
      case AppUserRole.strategyAnalyst:
        return '策略分析师';
      case AppUserRole.unknown:
        return '未知';
    }
  }

  /// 用户管理里可分配的角色（不含 unknown）
  static List<AppUserRole> assignableRoles() => [
        AppUserRole.customer,
        AppUserRole.trader,
        AppUserRole.admin,
        AppUserRole.strategyAnalyst,
      ];
}
