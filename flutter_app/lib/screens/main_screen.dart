import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../auth/app_user_role.dart';
import '../secure/prefs.dart';
import 'account_profit_screen.dart';
import 'accounts_list.dart';
import 'settings_screen.dart';
import 'tradingbot_control.dart';
import 'user_management_screen.dart';
import '../widgets/water_background.dart';

const _navBarTextColor = Color(0xFFD8D8D8); // RGB(216,216,216)

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, this.onLogout});

  final VoidCallback? onLogout;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _index = 0;
  List<UnifiedTradingBot> _sharedBots = [];
  final _prefs = SecurePrefs();
  AppUserRole _role = AppUserRole.trader;

  bool get _isCustomer => _role == AppUserRole.customer;

  /// 管理员：无「策略启停」Tab。
  bool get _isAdmin => _role == AppUserRole.admin;

  List<({String label, IconData icon})> get _tabs {
    if (_isCustomer) {
      return [
        (label: '账户收益', icon: Icons.account_balance_wallet),
        (label: '应用设置', icon: Icons.settings),
      ];
    }
    if (_isAdmin) {
      return [
        (label: '账户管理', icon: Icons.manage_accounts),
        (label: '账户收益', icon: Icons.account_balance_wallet),
        (label: '应用设置', icon: Icons.settings),
      ];
    }
    return [
      (label: '账户管理', icon: Icons.manage_accounts),
      (label: '策略启停', icon: Icons.smart_toy_outlined),
      (label: '账户收益', icon: Icons.account_balance_wallet),
      (label: '应用设置', icon: Icons.settings),
    ];
  }

  int get _profitTabIndex {
    if (_isCustomer) return 0;
    if (_isAdmin) return 1;
    return 2;
  }

  Future<void> _loadSharedBots() async {
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
    final r = await _prefs.getAppUserRole();
    if (mounted) setState(() => _role = r);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final me = await api.getMe();
      if (!mounted || !me.success) return;
      await _prefs.setUserRole(me.role);
      setState(() => _role = AppUserRole.fromApi(me.role));
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _loadRole();
    _loadSharedBots();
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted || _sharedBots.isNotEmpty) return;
      _loadSharedBots();
    });
  }

  Widget _body() {
    if (_isCustomer) {
      return IndexedStack(
        index: _index,
        sizing: StackFit.expand,
        children: [
          AccountProfitScreen(
            sharedBots: _sharedBots,
            periodicRefreshActive: _index == 0,
          ),
          SettingsScreen(
            onLogout: widget.onLogout,
            appUserRole: _role,
          ),
        ],
      );
    }
    if (_isAdmin) {
      return IndexedStack(
        index: _index,
        sizing: StackFit.expand,
        children: [
          const AccountsList(),
          AccountProfitScreen(
            sharedBots: _sharedBots,
            periodicRefreshActive: _index == 1,
          ),
          SettingsScreen(
            onLogout: widget.onLogout,
            appUserRole: _role,
            onOpenUserManagement: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const UserManagementScreen(),
                ),
              );
            },
          ),
        ],
      );
    }
    return IndexedStack(
      index: _index,
      sizing: StackFit.expand,
      children: [
        const AccountsList(),
        const TradingBotControl(),
        AccountProfitScreen(
          sharedBots: _sharedBots,
          periodicRefreshActive: _index == 2,
        ),
        SettingsScreen(
          onLogout: widget.onLogout,
          appUserRole: _role,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    if (_index >= tabs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _index = 0);
      });
    }
    final safeIndex = _index.clamp(0, tabs.length - 1);

    return Scaffold(
      body: WaterBackground(child: _body()),
      bottomNavigationBar: Theme(
        data: Theme.of(context).copyWith(
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: Colors.black,
            iconTheme: WidgetStateProperty.resolveWith((_) => const IconThemeData(
                  color: _navBarTextColor,
                  size: 24,
                )),
            labelTextStyle: WidgetStateProperty.resolveWith((_) => const TextStyle(
                  color: _navBarTextColor,
                  fontWeight: FontWeight.bold,
                )),
            indicatorColor: Colors.white24,
          ),
        ),
        child: NavigationBar(
          selectedIndex: safeIndex,
          onDestinationSelected: (i) {
            setState(() => _index = i);
            if (i == _profitTabIndex && _sharedBots.isEmpty) _loadSharedBots();
          },
          destinations: [
            for (final t in tabs)
              NavigationDestination(
                icon: Icon(t.icon),
                label: t.label,
              ),
          ],
        ),
      ),
    );
  }
}
