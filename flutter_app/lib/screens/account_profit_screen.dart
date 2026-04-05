import 'package:flutter/material.dart';

import '../api/models.dart';
import 'account_profit_page.dart';

/// 移动端「账户收益」Tab / 账户列表点入；业务实现见 [AccountProfitPage]。
class AccountProfitScreen extends StatelessWidget {
  const AccountProfitScreen({
    super.key,
    this.sharedBots = const [],
    this.initialBotId,
    this.periodicRefreshActive = true,
  });

  final List<UnifiedTradingBot> sharedBots;
  final String? initialBotId;
  final bool periodicRefreshActive;

  @override
  Widget build(BuildContext context) {
    return AccountProfitPage(
      sharedBots: sharedBots,
      initialBotId: initialBotId,
      periodicRefreshActive: periodicRefreshActive,
      useWebLayout: false,
      embedInShell: false,
    );
  }
}
