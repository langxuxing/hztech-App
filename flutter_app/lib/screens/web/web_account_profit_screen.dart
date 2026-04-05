import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../theme/finance_style.dart';
import '../account_profit_page.dart';

/// Web 端「账户收益 / 账户详情」：与移动端同一套 [AccountProfitPage] 能力（数据加载、
/// 账户切换、资产概览、收益率曲线、月底面板、持仓与赛季盈利），并启用 Web 布局语义。
///
/// - 视口宽度 ≥960px 时为左（概览+曲线+月度）右（持仓+赛季）分栏；更窄时为单列滚动。
/// - 内容在超宽屏下居中并限制最大宽度，避免两栏在极大分辨率下过度拉伸。
/// - 从「账号总览」「策略启停」等 [Navigator.push] 进入时保留本页 [AppBar]（可返回）。
/// - 嵌入 [WebMainShell] 时设 [embedInShell] 为 true，由外壳 [AppBar] 显示标题。
class WebAccountProfitScreen extends StatefulWidget {
  const WebAccountProfitScreen({
    super.key,
    this.sharedBots = const [],
    this.initialBotId,
    this.embedInShell = false,
    this.periodicRefreshActive = true,
  });

  /// 与仪表盘、策略页同源的交易账户列表；可为空，由页面自行拉取。
  final List<UnifiedTradingBot> sharedBots;

  /// 预选交易账户 ID（例如从仪表盘某张卡片点入）。
  final String? initialBotId;

  /// 为 true 时不渲染本页 [AppBar]，由外层壳展示标题。
  final bool embedInShell;

  /// 为 false 时不启动定时刷新（例如嵌在 [IndexedStack] 多 Tab 中需由外层控制时）。
  final bool periodicRefreshActive;

  @override
  State<WebAccountProfitScreen> createState() => _WebAccountProfitScreenState();
}

class _WebAccountProfitScreenState extends State<WebAccountProfitScreen> {
  static const double _maxContentWidth = 1680;

  @override
  Widget build(BuildContext context) {
    final page = AccountProfitPage(
      sharedBots: widget.sharedBots,
      initialBotId: widget.initialBotId,
      periodicRefreshActive: widget.periodicRefreshActive,
      useWebLayout: true,
      embedInShell: widget.embedInShell,
    );

    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _maxContentWidth) {
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                child: page,
              ),
            );
          }
          return page;
        },
      ),
    );
  }
}
