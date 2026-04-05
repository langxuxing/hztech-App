import 'package:flutter/material.dart';

import '../../api/models.dart';
import 'web_account_profile_screen.dart';

/// Web「账户详情」独立路由入口；实现已整合至 [WebAccountProfileScreen]。
///
/// 缺省 [embedInShell] 为 false（带返回栏的 AppBar），与仪表盘 / 策略页 push 行为一致。
class WebAccountProfitScreen extends StatelessWidget {
  const WebAccountProfitScreen({
    super.key,
    this.sharedBots = const [],
    this.initialBotId,
    this.embedInShell = false,
    this.periodicRefreshActive = true,
  });

  final List<UnifiedTradingBot> sharedBots;
  final String? initialBotId;
  final bool embedInShell;
  final bool periodicRefreshActive;

  @override
  Widget build(BuildContext context) {
    return WebAccountProfileScreen(
      sharedBots: sharedBots,
      initialBotId: initialBotId,
      embedInShell: embedInShell,
      periodicRefreshActive: periodicRefreshActive,
    );
  }
}
