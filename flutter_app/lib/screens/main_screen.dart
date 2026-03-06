import 'package:flutter/material.dart';

import 'account_profit_screen.dart';
import 'bot_list_screen.dart';
import 'settings_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, this.onLogout});

  final VoidCallback? onLogout;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _index = 0;

  static const _tabs = [
    ('账户概况', Icons.account_balance_wallet),
    ('策略管理', Icons.smart_toy),
    ('设置', Icons.settings),
  ];

  Widget _body() {
    switch (_index) {
      case 0:
        return const AccountProfitScreen();
      case 1:
        return const BotListScreen();
      case 2:
        return SettingsScreen(onLogout: widget.onLogout);
      default:
        return const AccountProfitScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _body(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: _tabs
            .map((e) => NavigationDestination(
                  icon: Icon(e.$2),
                  label: e.$1,
                ))
            .toList(),
      ),
    );
  }
}
