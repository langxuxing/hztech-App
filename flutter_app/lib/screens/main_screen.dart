import 'package:flutter/material.dart';

import 'account_profit_screen.dart';
import 'bot_list_screen.dart';
import 'settings_screen.dart';
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
    ('策略管理', Icons.smart_toy),
    ('机器人收益', Icons.account_balance_wallet),
    ('应用设置', Icons.settings),
  ];

  Future<void> _loadSharedBots() async {
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.getTradingBots();
      if (!mounted) return;

      // 打印获取到的 botList 到控制台
      // ignore: avoid_print
      print('botList: ${resp.botList}');
      setState(() => _sharedBots = resp.botList);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _loadSharedBots();
  }

  Widget _body() {
    switch (_index) {
      case 0:
        return const BotListScreen();
      case 1:
        return AccountProfitScreen(sharedBots: _sharedBots);
      case 2:
        return SettingsScreen(onLogout: widget.onLogout);
      default:
        return const BotListScreen();
    }
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
            // 切到机器人收益时若列表仍空则再拉一次（与策略管理同源）
            if (i == 1 && _sharedBots.isEmpty) _loadSharedBots();
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
