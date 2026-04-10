/// 全应用轮询仅使用三档间隔（秒）：健康检查、切片类刷新、慢刷新。
class PollIntervals {
  PollIntervals._();

  /// 健康检查等轻量探测（如 `/api/health`）。
  static const Duration shortPoll = Duration(seconds: 3);

  /// 账户汇总 + 持仓等切片刷新；策略启停页纯 UI tick；OKX 公共 WS ping。
  static const Duration mediumPoll = Duration(seconds: 30);

  /// 持仓列表轮询、收益曲线快照等低频刷新。
  static const Duration slowPoll = Duration(seconds: 120);

  /// [AccountProfitScreen] 客户角色：弱网减负，切片刷新间隔长于 [mediumPoll]。
  static const Duration accountProfitCustomerLivePoll = Duration(seconds: 45);

  /// [AccountProfitScreen] 客户角色：收益历史快照刷新间隔长于 [slowPoll]。
  static const Duration accountProfitCustomerHistoryPoll =
      Duration(seconds: 300);
}
