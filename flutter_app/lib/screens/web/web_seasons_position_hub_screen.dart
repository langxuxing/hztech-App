import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../auth/app_user_role.dart';
import '../../theme/finance_style.dart';
import 'web_position_history_screen.dart';
import 'web_seasons_screen.dart';

/// 赛季与历史仓位合并入口：顶部分栏切换，子页逻辑仍由各自 Screen 承担。
class WebSeasonsPositionHubScreen extends StatefulWidget {
  const WebSeasonsPositionHubScreen({
    super.key,
    required this.sharedBots,
    required this.appUserRole,
  });

  final List<UnifiedTradingBot> sharedBots;
  final AppUserRole appUserRole;

  @override
  State<WebSeasonsPositionHubScreen> createState() =>
      _WebSeasonsPositionHubScreenState();
}

class _WebSeasonsPositionHubScreenState extends State<WebSeasonsPositionHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.white.withValues(alpha: 0.04),
          child: TabBar(
            controller: _tabController,
            labelColor: AppFinanceStyle.profitGreenEnd,
            unselectedLabelColor: AppFinanceStyle.labelColor,
            indicatorColor: AppFinanceStyle.profitGreenEnd,
            tabs: const [
              Tab(text: '赛季'),
              Tab(text: '历史仓位'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              WebSeasonsScreen(
                sharedBots: widget.sharedBots,
                embedInShell: true,
              ),
              WebPositionHistoryScreen(
                sharedBots: widget.sharedBots,
                embedInShell: true,
                appUserRole: widget.appUserRole,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
