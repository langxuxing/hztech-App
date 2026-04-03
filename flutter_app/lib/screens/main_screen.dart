import 'package:flutter/material.dart';

import 'account_profit_screen.dart';
import 'accounts_list.dart';
import 'settings_screen.dart';
import 'tradingbot_control.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
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

  static const _tabs = [
    ('账户管理', Icons.manage_accounts),
    ('策略启停', Icons.smart_toy_outlined),
    ('账户收益', Icons.account_balance_wallet),
    ('应用设置', Icons.settings),
  ];

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

  @override
  void initState() {
    super.initState();
    _loadSharedBots();
    // 若首包较慢或失败，1.5s 后再拉一次，提高 sharedBots 到达子页的概率
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted || _sharedBots.isNotEmpty) return;
      _loadSharedBots();
    });
  }

  /// 使用 IndexedStack 让三个 Tab 子页常驻，避免「仅切到账户收益时才创建 AccountProfitScreen」
  /// 导致 sharedBots 长期为空、下拉框不出现；父级 _loadSharedBots 完成后子页可立即 didUpdateWidget。
  Widget _body() {
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
        SettingsScreen(onLogout: widget.onLogout),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
          selectedIndex: _index,
          onDestinationSelected: (i) {
            setState(() => _index = i);
            // 切到账户收益时若列表仍空则再拉一次（与账户管理同源）
            if (i == 2 && _sharedBots.isEmpty) _loadSharedBots();
          },
          destinations: _tabs
              .map((e) => NavigationDestination(
                    icon: Icon(e.$2),
                    label: e.$1,
                  ))
              .toList(),
        ),
      ),
    );
  }
}
