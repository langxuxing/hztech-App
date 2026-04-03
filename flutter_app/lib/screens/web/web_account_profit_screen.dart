import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../account_profit_screen.dart';

/// Web 端「账户详情」：与 [AccountProfitScreen] 共用同一套数据加载、账户切换、
/// 资产概览、收益率曲线、月底柱状图与日历、持仓（含价格轴）与赛季盈利；
/// 固定开启 [AccountProfitScreen.webLayout]，在视口宽度 ≥960px 时采用
/// 左（概览+曲线+月度）右（持仓+赛季）分栏。
///
/// - 从「策略启动」或「仪表盘」等页经 [Navigator.push] 进入时显示自带返回的标题栏。
/// - 若将来嵌入 [WebMainShell] 等外壳，可将 [embedInShell] 设为 `true` 以隐藏本页 [AppBar]。
class WebAccountProfitScreen extends StatefulWidget {
  const WebAccountProfitScreen({
    super.key,
    this.sharedBots = const [],
    this.initialBotId,
    this.embedInShell = false,
  });

  /// 与仪表盘、策略页同源的交易账户列表；可为空，此时由 [AccountProfitScreen] 自行拉取。
  final List<UnifiedTradingBot> sharedBots;

  /// 预选交易账户 ID（例如从仪表盘某张卡片点入）。
  final String? initialBotId;

  /// 为 true 时不渲染本页 [AppBar]，由外层壳展示标题。
  final bool embedInShell;

  @override
  State<WebAccountProfitScreen> createState() => _WebAccountProfitScreenState();
}

class _WebAccountProfitScreenState extends State<WebAccountProfitScreen> {
  @override
  Widget build(BuildContext context) {
    return AccountProfitScreen(
      sharedBots: widget.sharedBots,
      initialBotId: widget.initialBotId,
      webLayout: true,
      periodicRefreshActive: true,
      embedInShell: widget.embedInShell,
    );
  }
}
