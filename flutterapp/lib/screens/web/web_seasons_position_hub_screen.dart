import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../auth/app_user_role.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';
import 'web_position_history_screen.dart';
import 'web_seasons_screen.dart';

/// 赛季与历史仓位合并入口：顶部统一账户选择 → Tab（赛季 | 历史仓位）。
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
  String? _accountId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    if (widget.sharedBots.isNotEmpty) {
      _accountId = widget.sharedBots.first.tradingbotId;
    }
  }

  @override
  void didUpdateWidget(WebSeasonsPositionHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sharedBots.isEmpty) {
      if (_accountId != null) setState(() => _accountId = null);
      return;
    }
    final valid = widget.sharedBots.any((b) => b.tradingbotId == _accountId);
    if (!valid) {
      setState(() => _accountId = widget.sharedBots.first.tradingbotId);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String? _symbolForSelectedAccount() {
    final id = _accountId;
    if (id == null) return null;
    for (final b in widget.sharedBots) {
      if (b.tradingbotId == id) {
        final s = b.symbol;
        if (s != null && s.isNotEmpty) return s;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // 布局：账户选择置顶 → 其下为「赛季 | 历史仓位」Tab（子页不再重复账户下拉）。
    // 与 [WebAccountProfileScreen] / [WebStrategyPerformanceScreen] 相同底图；子 Tab 内不再重复叠 WaterBackground。
    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
        Material(
          color: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (MediaQuery.sizeOf(context).width * 0.45).clamp(
                    160.0,
                    280.0,
                  ),
                  minHeight: kMinInteractiveDimension,
                ),
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: _accountId != null &&
                          widget.sharedBots
                              .any((b) => b.tradingbotId == _accountId)
                      ? _accountId
                      : null,
                  decoration: InputDecoration(
                    labelText: '账户',
                    labelStyle: AppFinanceStyle.labelTextStyle(context),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                  ),
                  dropdownColor: const Color(0xFF1a1a24),
                  style: TextStyle(color: AppFinanceStyle.valueColor),
                  items: widget.sharedBots
                      .map(
                        (b) => DropdownMenuItem(
                          value: b.tradingbotId,
                          child: Text(
                            (b.tradingbotName != null &&
                                    b.tradingbotName!.isNotEmpty)
                                ? b.tradingbotName!
                                : b.tradingbotId,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: widget.sharedBots.isEmpty
                      ? null
                      : (v) => setState(() => _accountId = v),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Material(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
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
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              WebSeasonsScreen(
                sharedBots: widget.sharedBots,
                embedInShell: true,
                accountIdFromParent: _accountId,
                marketSymbol: _symbolForSelectedAccount(),
              ),
              WebPositionHistoryScreen(
                sharedBots: widget.sharedBots,
                embedInShell: true,
                appUserRole: widget.appUserRole,
                accountIdFromParent: _accountId,
              ),
            ],
          ),
        ),
      ],
        ),
      ),
    );
  }
}
