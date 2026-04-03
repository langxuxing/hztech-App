import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../settings_screen.dart';
import '../tradingbot_control.dart';
import 'download_app_page.dart';
import 'web_dashboard_screen.dart';
import 'web_home_screen.dart';
import 'web_strategy_performance_screen.dart';

/// 浏览器端主导航：侧栏 / 抽屉 + 多 Tab，与移动端 [MainScreen] 分流。
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

  static const _titles = [
    '主页',
    '仪表盘',
    '策略启停',
    '账户收益与详情',
    '下载 App',
    '设置',
  ];

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

  @override
  void initState() {
    super.initState();
    _loadBots();
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted || _sharedBots.isNotEmpty) return;
      _loadBots();
    });
  }

  @override
  Widget build(BuildContext context) {
    final useRail = MediaQuery.sizeOf(context).width >= 760;
    final body = IndexedStack(
      index: _index,
      sizing: StackFit.expand,
      children: [
        const WebHomeScreen(),
        WebDashboardScreen(sharedBots: _sharedBots),
        const TradingBotControl(embedInShell: true),
        WebStrategyPerformanceScreen(sharedBots: _sharedBots),
        const DownloadAppPage(),
        SettingsScreen(
          embedInShell: true,
          onLogout: widget.onLogout,
        ),
      ],
    );

    if (useRail) {
      return Scaffold(
        backgroundColor: AppFinanceStyle.backgroundDark,
        appBar: AppBar(
          title: Text(
            _titles[_index],
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
              selectedIndex: _index,
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
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: Text('欢迎页'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: Text('仪表盘'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.smart_toy_outlined),
                  selectedIcon: Icon(Icons.smart_toy),
                  label: Text('策略启停'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.insights_outlined),
                  selectedIcon: Icon(Icons.insights),
                  label: Text('账户收益与详情'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.download_outlined),
                  selectedIcon: Icon(Icons.download),
                  label: Text('APK下载'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: Text('设置'),
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
          _titles[_index],
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
            for (var i = 0; i < _titles.length; i++)
              ListTile(
                selected: _index == i,
                selectedTileColor: Colors.white12,
                title: Text(
                  _titles[i],
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
