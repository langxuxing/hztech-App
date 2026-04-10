import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_update_prompt.dart';
import '../auth/app_user_role.dart';
import '../debug_ingest_log.dart';
import '../secure/prefs.dart';
import 'accounts_profits_dashboard.dart';
import 'account_profit_screen.dart';
import 'accounts_list.dart';
import 'settings_screen.dart';
import 'tradingbot_control.dart';
import 'user_management_screen.dart';
import '../theme/finance_style.dart';
import '../widgets/water_background.dart';

const _navBarTextColor = AppFinanceStyle.textDefault;

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

  /// 角色从缓存/接口更新后，按「同一底栏标签」重映射 [_index]，避免 tab 数量变化时仍沿用旧索引而跳到错误页面（例如「本月收益」一闪后变成「设置」）。
  void _remapNavIndexForNewRole(AppUserRole newRole) {
    final oldTabs = _tabs;
    final maxOld = oldTabs.isEmpty ? 0 : oldTabs.length - 1;
    final oldIndex = _index.clamp(0, maxOld);
    final label = oldTabs.isNotEmpty ? oldTabs[oldIndex].label : null;
    final oldRole = _role.apiValue;
    final oldIndexRaw = _index;
    _role = newRole;
    final newTabs = _tabs;
    if (newTabs.isEmpty) {
      _index = 0;
      return;
    }
    if (label != null) {
      final j = newTabs.indexWhere((t) => t.label == label);
      if (j >= 0) {
        _index = j;
        return;
      }
    }
    _index = _index.clamp(0, newTabs.length - 1);
    // #region agent log
    unawaited(
      debugIngestLog(
        location: 'main_screen.dart:_remapNavIndexForNewRole',
        message: 'role_remap_applied',
        hypothesisId: 'H1',
        data: <String, Object?>{
          'oldRole': oldRole,
          'newRole': newRole.apiValue,
          'oldIndex': oldIndexRaw,
          'oldLabel': label,
          'newIndex': _index,
          'newLabel': newTabs.isNotEmpty ? newTabs[_index].label : null,
          'newTabsCount': newTabs.length,
        },
      ),
    );
    // #endregion
  }

  bool get _isCustomer => _role == AppUserRole.customer;

  /// 管理员：无「策略启停」Tab。
  bool get _isAdmin => _role == AppUserRole.admin;

  /// 策略分析师：与管理员类似无「策略启停」；自动收网测试在 Web 侧栏。
  bool get _isStrategyAnalyst => _role == AppUserRole.strategyAnalyst;

  List<({String label, IconData icon})> get _tabs {
    if (_isCustomer) {
      return [
        (label: '本月收益', icon: Icons.trending_up),
        (label: '应用设置', icon: Icons.settings),
      ];
    }
    if (_isAdmin) {
      return [
        (label: '账户总览', icon: Icons.manage_accounts),
        (label: '策略启停', icon: Icons.smart_toy_outlined),
        (label: '策略盈利', icon: Icons.insights_outlined),
        (label: '本月收益', icon: Icons.account_balance_wallet),
        (label: '应用设置', icon: Icons.settings),
      ];
    }
    if (_isStrategyAnalyst) {
      return [
        (label: '账户总览', icon: Icons.manage_accounts),
        (label: '策略盈利', icon: Icons.insights_outlined),
        (label: '本月收益', icon: Icons.account_balance_wallet),
        (label: '应用设置', icon: Icons.settings),
      ];
    }
    return [
      (label: '账户总览', icon: Icons.manage_accounts),
      (label: '策略启停', icon: Icons.smart_toy_outlined),
      (label: '策略盈利', icon: Icons.insights_outlined),
      (label: '本月收益', icon: Icons.account_balance_wallet),
      (label: '应用设置', icon: Icons.settings),
    ];
  }

  int get _profitTabIndex {
    if (_isCustomer) return 0;
    if (_isAdmin) return 3;
    if (_isStrategyAnalyst) return 2;
    return 3;
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
    if (mounted) {
      setState(() => _remapNavIndexForNewRole(r));
    }
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final me = await api.getMe();
      if (!mounted || !me.success) return;
      await _prefs.setUserRole(me.role);
      if (mounted) {
        setState(() => _remapNavIndexForNewRole(AppUserRole.fromApi(me.role)));
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _loadRole();
    _loadSharedBots();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final url = await _prefs.backendBaseUrl;
      if (!mounted) return;
      await AppUpdatePrompt.checkIfNeeded(context, url);
    });
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
            showRealtimeAppBarTitle: true,
          ),
          SettingsScreen(onLogout: widget.onLogout, appUserRole: _role),
        ],
      );
    }
    if (_isAdmin) {
      return IndexedStack(
        index: _index,
        sizing: StackFit.expand,
        children: [
          AccountsList(
            sharedBots: _sharedBots,
            periodicRefreshActive: _index == 0,
          ),
          const TradingBotControl(),
          const AccountProfitDetailScreen(),
          AccountProfitScreen(
            sharedBots: _sharedBots,
            periodicRefreshActive: _index == 3,
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
    if (_isStrategyAnalyst) {
      return IndexedStack(
        index: _index,
        sizing: StackFit.expand,
        children: [
          AccountsList(
            sharedBots: _sharedBots,
            periodicRefreshActive: _index == 0,
          ),
          const AccountProfitDetailScreen(),
          AccountProfitScreen(
            sharedBots: _sharedBots,
            periodicRefreshActive: _index == 2,
          ),
          SettingsScreen(onLogout: widget.onLogout, appUserRole: _role),
        ],
      );
    }
    return IndexedStack(
      index: _index,
      sizing: StackFit.expand,
      children: [
        AccountsList(
          sharedBots: _sharedBots,
          periodicRefreshActive: _index == 0,
        ),
        const TradingBotControl(),
        const AccountProfitDetailScreen(),
        AccountProfitScreen(
          sharedBots: _sharedBots,
          periodicRefreshActive: _index == 3,
        ),
        SettingsScreen(onLogout: widget.onLogout, appUserRole: _role),
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
            iconTheme: WidgetStateProperty.resolveWith(
              (_) => const IconThemeData(color: _navBarTextColor, size: 24),
            ),
            labelTextStyle: WidgetStateProperty.resolveWith(
              (_) => const TextStyle(
                color: _navBarTextColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            indicatorColor: AppFinanceStyle.textDefault.withValues(alpha: 0.24),
          ),
        ),
        child: NavigationBar(
          selectedIndex: safeIndex,
          onDestinationSelected: (i) {
            final tabsNow = _tabs;
            // #region agent log
            unawaited(
              debugIngestLog(
                location: 'main_screen.dart:onDestinationSelected',
                message: 'nav_tap',
                hypothesisId: 'H1',
                data: <String, Object?>{
                  'tapIndex': i,
                  'tapLabel':
                      (i >= 0 && i < tabsNow.length) ? tabsNow[i].label : null,
                  'role': _role.apiValue,
                  'tabsCount': tabsNow.length,
                },
              ),
            );
            // #endregion
            setState(() => _index = i);
            if (i == _profitTabIndex && _sharedBots.isEmpty) _loadSharedBots();
          },
          destinations: [
            for (final t in tabs)
              NavigationDestination(icon: Icon(t.icon), label: t.label),
          ],
        ),
      ),
    );
  }
}
