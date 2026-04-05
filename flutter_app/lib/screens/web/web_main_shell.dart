import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../auth/app_user_role.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../settings_screen.dart';
import '../user_management_screen.dart';
import 'download_app_page.dart';
import 'tradingbot_control_screen.dart';
import 'web_dashboard_screen.dart';
import 'web_home_screen.dart';
import 'web_account_profile_screen.dart';
import 'web_strategy_performance_screen.dart';

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
/// 顺序：主页 → 仪表盘 → 账户收益 → 策略能效 → 策略启停（交易员/管理员）
/// → 用户管理（管理员）→ 下载 → 设置。
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
          title: '账号总览',
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
          page: WebDashboardScreen(sharedBots: bots),
        ),

      if (_role.canViewStrategyPerformance)
        _NavItem(
          title: '账户收益',
          icon: Icons.insights_outlined,
          selectedIcon: Icons.insights,
          page: WebAccountProfileScreen(sharedBots: bots),
        ),
      if (_role.canViewStrategyPerformance)
        _NavItem(
          title: '策略能效',
          icon: Icons.speed_outlined,
          selectedIcon: Icons.speed,
          page: WebStrategyPerformanceScreen(sharedBots: bots),
        ),
      if (_role.canViewStrategyStart)
        _NavItem(
          title: '策略启停',
          icon: Icons.play_circle_outline,
          selectedIcon: Icons.play_circle,
          page: WebTradingBotControlScreen(sharedBots: bots),
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
        page: DownloadAppPage(),
      ),
      _NavItem(
        title: '设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        page: SettingsScreen(
          embedInShell: true,
          onLogout: widget.onLogout,
          appUserRole: _role,
        ),
      ),
    ];
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
    final items = _itemsForRole();
    _clampIndex(items.length);
    final useRail = MediaQuery.sizeOf(context).width >= 760;
    final body = IndexedStack(
      index: _index.clamp(0, items.length - 1),
      sizing: StackFit.expand,
      children: items.map((e) => e.page).toList(),
    );

    if (useRail) {
      return Scaffold(
        backgroundColor: AppFinanceStyle.backgroundDark,
        appBar: AppBar(
          title: Text(
            items[_index.clamp(0, items.length - 1)].title,
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
              color: AppFinanceStyle.valueColor,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          backgroundColor: AppFinanceStyle.backgroundDark,
          foregroundColor: AppFinanceStyle.valueColor,
          surfaceTintColor: Colors.transparent,
        ),
        body: Row(
          children: [
            NavigationRail(
              backgroundColor: const Color(0xFF0f0f14),
              selectedIndex: _index.clamp(0, items.length - 1),
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              selectedLabelTextStyle: const TextStyle(
                color: AppFinanceStyle.valueColor,
                fontSize: 12,
              ),
              unselectedLabelTextStyle: const TextStyle(
                color: AppFinanceStyle.labelColor,
                fontSize: 12,
              ),
              destinations: [
                for (final e in items)
                  NavigationRailDestination(
                    icon: Icon(e.icon),
                    selectedIcon: Icon(e.selectedIcon),
                    label: Text(e.title),
                  ),
              ],
            ),
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
          items[_index.clamp(0, items.length - 1)].title,
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
