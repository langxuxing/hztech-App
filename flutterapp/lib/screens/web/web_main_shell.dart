import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../auth/app_user_role.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../settings_screen.dart';
import '../user_management_screen.dart';
import 'web_auto_netting_test_screen.dart';
import 'web_download_app_page.dart';
import 'web_tradingbot_control_screen.dart';
import 'web_dashboard_screen.dart';
import 'web_home_screen.dart';
import 'web_account_profit_screen.dart';
import 'web_strategy_performance_screen.dart';
import 'web_account_performance_screen.dart';
import 'web_seasons_position_hub_screen.dart';
import 'web_account_config_admin_screen.dart';
import 'web_service_status_screen.dart';
import '../customer_account_setup_screen.dart';

class _NavItem {
  const _NavItem({
    required this.title,
    required this.icon,
    required this.selectedIcon,
    required this.page,
  });

  final String title;
  final IconData icon;
  final IconData selectedIcon;
  final Widget page;
}

/// 浏览器端主导航：侧栏 / 抽屉 + 多 Tab，与移动端 [MainScreen] 分流。
/// 客户（customer）：仅「账户详情」全宽单页，无侧栏；更多菜单含 OKX 账户配置与退出登录。
/// 其他角色侧栏顺序：主页 → 仪表盘 → 账户收益 → 策略启停 → 策略能效 → 绩效对比表 → 赛季与历史仓位
/// → 收网测试（交易员/管理员/策略分析师）→ 账户配置（客户 OKX JSON，仅非 Web 客户壳）→ 账户管理 / 用户管理（管理员）→ 下载 → 设置。
class WebMainShell extends StatefulWidget {
  const WebMainShell({super.key, this.onLogout});

  final VoidCallback? onLogout;

  @override
  State<WebMainShell> createState() => _WebMainShellState();
}

class _WebMainShellState extends State<WebMainShell> {
  final _prefs = SecurePrefs();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _index = 0;
  List<UnifiedTradingBot> _sharedBots = [];
  AppUserRole _role = AppUserRole.trader;

  /// 仪表盘卡片点入「账户收益」时一帧内下发，供 [WebAccountProfitScreen.initialBotId] 触发切换账户。
  String? _profitInitialFromDashboard;

  List<_NavItem> _itemsForRole() {
    final bots = _sharedBots;
    return [
      const _NavItem(
        title: '金融动力学',
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        page: WebHomeScreen(),
      ),
      if (_role.canViewGlobalDashboard)
        _NavItem(
          title: '账户总览',
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
          page: WebDashboardScreen(
            sharedBots: bots,
            onOpenAccountProfit: _openAccountProfitFromDashboard,
          ),
        ),

      if (_role.canViewStrategyPerformance)
        _NavItem(
          title: '账户收益',
          icon: Icons.insights_outlined,
          selectedIcon: Icons.insights,
          page: WebAccountProfitScreen(
            sharedBots: bots,
            embedInShell: true,
            initialBotId: _profitInitialFromDashboard,
          ),
        ),
      if (_role.canViewStrategyStart)
        _NavItem(
          title: '策略启停',
          icon: Icons.play_circle_outline,
          selectedIcon: Icons.play_circle,
          page: WebTradingBotControlScreen(sharedBots: bots),
        ),
      if (_role.canViewStrategyPerformance)
        _NavItem(
          title: '策略能效',
          icon: Icons.speed_outlined,
          selectedIcon: Icons.speed,
          page: WebStrategyPerformanceScreen(sharedBots: bots),
        ),
      if (_role.canViewAccountPerformanceComparison)
        _NavItem(
          title: '绩效赛马',
          icon: Icons.table_chart_outlined,
          selectedIcon: Icons.table_chart,
          page: WebAccountPerformanceScreen(
            sharedBots: bots,
            embedInShell: true,
          ),
        ),
      if (_role.canViewStrategyPerformance)
        _NavItem(
          title: '赛季与历史仓位',
          icon: Icons.emoji_events_outlined,
          selectedIcon: Icons.emoji_events,
          page: WebSeasonsPositionHubScreen(
            sharedBots: bots,
            appUserRole: _role,
          ),
        ),
      if (_role.canConfigureLinkedOkxKeys)
        _NavItem(
          title: '账户配置',
          icon: Icons.vpn_key_outlined,
          selectedIcon: Icons.vpn_key,
          page: const CustomerAccountSetupScreen(embedInShell: true),
        ),
      if (_role.canViewAutoNettingTest)
        _NavItem(
          title: '收网测试',
          icon: Icons.science_outlined,
          selectedIcon: Icons.science,
          page: WebAutoNettingTestScreen(sharedBots: bots, embedInShell: true),
        ),
      if (_role.canManageUsers)
        _NavItem(
          title: '账户管理',
          icon: Icons.account_balance_wallet_outlined,
          selectedIcon: Icons.account_balance_wallet,
          page: const WebAccountConfigAdminScreen(embedInShell: true),
        ),
      if (_role.canManageUsers)
        _NavItem(
          title: '用户管理',
          icon: Icons.group_outlined,
          selectedIcon: Icons.group,
          page: UserManagementScreen(embedInShell: true),
        ),
      const _NavItem(
        title: 'APK下载',
        icon: Icons.download_outlined,
        selectedIcon: Icons.download,
        page: WebDownloadAppPage(),
      ),
      _NavItem(
        title: '设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        page: SettingsScreen(
          embedInShell: true,
          onLogout: widget.onLogout,
          appUserRole: _role,
          onOpenUserManagement: _role.canManageUsers
              ? _openUserManagementFromSettings
              : null,
        ),
      ),
    ];
  }

  /// 左侧可滚动导航（宽屏），避免 NavigationRail 在垂直空间不足时裁切底部项。
  Widget _buildScrollableSideNav(List<_NavItem> items) {
    return Material(
      color: const Color(0xFF0f0f14),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final e = items[i];
          final selected = _index == i;
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _index = i),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 10,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      selected ? e.selectedIcon : e.icon,
                      color: selected
                          ? AppFinanceStyle.profitGreenEnd
                          : AppFinanceStyle.labelColor,
                      size: 26,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      e.title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? AppFinanceStyle.valueColor
                            : AppFinanceStyle.labelColor,
                        fontSize: 11,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        height: 1.15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _loadBots() async {
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.getTradingBots();
      if (!mounted) return;
      setState(() => _sharedBots = resp.botList);
    } catch (_) {}
  }

  Future<void> _loadRole() async {
    final fromPrefs = await _prefs.getAppUserRole();
    if (!mounted) return;
    setState(() => _role = fromPrefs);
    try {
      final base = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(base, token: token);
      final me = await api.getMe();
      if (!mounted || !me.success) return;
      await _prefs.setUserRole(me.role);
      setState(() => _role = AppUserRole.fromApi(me.role));
    } catch (_) {}
  }

  void _clampIndex(int len) {
    if (_index >= len) setState(() => _index = 0);
  }

  /// 设置页「用户管理」按钮：跳到侧栏同名入口。
  void _openUserManagementFromSettings() {
    final items = _itemsForRole();
    final i = items.indexWhere((e) => e.title == '用户管理');
    if (i >= 0) setState(() => _index = i);
  }

  int? _indexOfNavTitle(String title) {
    final items = _itemsForRole();
    final i = items.indexWhere((e) => e.title == title);
    return i >= 0 ? i : null;
  }

  void _openAccountProfitFromDashboard(String? botId) {
    final i = _indexOfNavTitle('账户收益');
    if (i == null) return;
    final t = botId?.trim();
    final id = (t == null || t.isEmpty) ? null : t;
    setState(() {
      _profitInitialFromDashboard = id;
      _index = i;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _profitInitialFromDashboard = null);
    });
  }

  Future<void> _customerLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出登录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _prefs.clearOnLogout();
    if (!mounted) return;
    widget.onLogout?.call();
  }

  void _openCustomerOkxSetup(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          backgroundColor: AppFinanceStyle.backgroundDark,
          appBar: AppBar(
            title: Text(
              '账户配置',
              style: AppFinanceStyle.labelTextStyle(
                ctx,
              ).copyWith(color: AppFinanceStyle.valueColor, fontSize: 18),
            ),
            backgroundColor: AppFinanceStyle.backgroundDark,
            foregroundColor: AppFinanceStyle.valueColor,
            surfaceTintColor: Colors.transparent,
          ),
          body: const CustomerAccountSetupScreen(embedInShell: false),
        ),
      ),
    );
  }

  /// Web 客户：仅账户详情 + 顶栏菜单（无侧栏）。
  Widget _buildCustomerShell(BuildContext context) {
    final titleStyle = AppFinanceStyle.labelTextStyle(context).copyWith(
      color: AppFinanceStyle.valueColor,
      fontSize: 18,
      fontWeight: FontWeight.w600,
    );
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text('账户详情', style: titleStyle),
        backgroundColor: AppFinanceStyle.backgroundDark,
        foregroundColor: AppFinanceStyle.valueColor,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: const Color(0xFF1e1e28),
            onSelected: (v) {
              if (v == 'okx') {
                _openCustomerOkxSetup(context);
              } else if (v == 'logout') {
                _customerLogout(context);
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'okx', child: Text('账户配置（OKX）')),
              PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
        ],
      ),
      body: WebAccountProfitScreen(
        sharedBots: _sharedBots,
        embedInShell: true,
        periodicRefreshActive: true,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadBots();
    _loadRole();
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted || _sharedBots.isNotEmpty) return;
      _loadBots();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_role == AppUserRole.customer) {
      return _buildCustomerShell(context);
    }
    final items = _itemsForRole();
    _clampIndex(items.length);
    final idx = _index.clamp(0, items.length - 1);
    final useRail = MediaQuery.sizeOf(context).width >= 760;
    final body = IndexedStack(
      index: idx,
      sizing: StackFit.expand,
      children: items.map((e) => e.page).toList(),
    );

    if (useRail) {
      return Scaffold(
        backgroundColor: AppFinanceStyle.backgroundDark,
        appBar: AppBar(
          title: Text(
            items[idx].title,
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
              color: AppFinanceStyle.valueColor,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          backgroundColor: AppFinanceStyle.backgroundDark,
          foregroundColor: AppFinanceStyle.valueColor,
          surfaceTintColor: Colors.transparent,
          actions: [
            IconButton(
              tooltip: '服务状态',
              icon: const Icon(Icons.monitor_heart_outlined),
              onPressed: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (ctx) => const WebServiceStatusScreen(),
                  ),
                );
              },
            ),
          ],
        ),
        body: Row(
          children: [
            SizedBox(width: 104, child: _buildScrollableSideNav(items)),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          items[idx].title,
          style: AppFinanceStyle.labelTextStyle(context).copyWith(
            color: AppFinanceStyle.valueColor,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: AppFinanceStyle.backgroundDark,
        foregroundColor: AppFinanceStyle.valueColor,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        actions: [
          IconButton(
            tooltip: '服务状态',
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (ctx) => const WebServiceStatusScreen(),
                ),
              );
            },
          ),
        ],
      ),
      drawer: Drawer(
        backgroundColor: const Color(0xFF12121a),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            const DrawerHeader(
              margin: EdgeInsets.zero,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  '禾正量化',
                  style: TextStyle(
                    color: AppFinanceStyle.valueColor,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            for (var i = 0; i < items.length; i++)
              ListTile(
                selected: _index == i,
                selectedTileColor: Colors.white12,
                title: Text(
                  items[i].title,
                  style: TextStyle(
                    color: _index == i
                        ? AppFinanceStyle.profitGreenEnd
                        : AppFinanceStyle.valueColor,
                  ),
                ),
                onTap: () {
                  setState(() => _index = i);
                  Navigator.of(context).pop();
                },
              ),
          ],
        ),
      ),
      body: body,
    );
  }
}
