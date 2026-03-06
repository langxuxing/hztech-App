/// 账户盈利接口模型
class AccountProfitResponse {
  final bool success;
  final List<AccountProfit>? accounts;
  final int? totalCount;

  AccountProfitResponse({
    required this.success,
    this.accounts,
    this.totalCount,
  });

  factory AccountProfitResponse.fromJson(Map<String, dynamic> json) {
    return AccountProfitResponse(
      success: json['success'] as bool? ?? false,
      accounts: (json['accounts'] as List<dynamic>?)
          ?.map((e) => AccountProfit.fromJson(e as Map<String, dynamic>))
          .toList(),
      totalCount: json['total_count'] as int?,
    );
  }
}

class AccountProfit {
  final String exchangeAccount;
  final double initialBalance;
  final double currentBalance;
  final double profitAmount;
  final double profitPercent;
  final double floatingProfit;
  final double equityUsdt;
  final String? snapshotTime;

  AccountProfit({
    required this.exchangeAccount,
    required this.initialBalance,
    required this.currentBalance,
    required this.profitAmount,
    required this.profitPercent,
    required this.floatingProfit,
    required this.equityUsdt,
    this.snapshotTime,
  });

  factory AccountProfit.fromJson(Map<String, dynamic> json) {
    return AccountProfit(
      exchangeAccount: json['exchange_account'] as String? ?? '',
      initialBalance: (json['initial_balance'] as num?)?.toDouble() ?? 0,
      currentBalance: (json['current_balance'] as num?)?.toDouble() ?? 0,
      profitAmount: (json['profit_amount'] as num?)?.toDouble() ?? 0,
      profitPercent: (json['profit_percent'] as num?)?.toDouble() ?? 0,
      floatingProfit: (json['floating_profit'] as num?)?.toDouble() ?? 0,
      equityUsdt: (json['equity_usdt'] as num?)?.toDouble() ?? 0,
      snapshotTime: json['snapshot_time'] as String?,
    );
  }
}

/// 交易机器人列表
class TradingBotsResponse {
  final List<UnifiedTradingBot>? bots;
  final List<UnifiedTradingBot>? tradingbots;
  final int? total;

  TradingBotsResponse({this.bots, this.tradingbots, this.total});

  List<UnifiedTradingBot> get botList => bots ?? tradingbots ?? [];

  factory TradingBotsResponse.fromJson(Map<String, dynamic> json) {
    return TradingBotsResponse(
      bots: (json['bots'] as List<dynamic>?)
          ?.map((e) => UnifiedTradingBot.fromJson(e as Map<String, dynamic>))
          .toList(),
      tradingbots: (json['tradingbots'] as List<dynamic>?)
          ?.map((e) => UnifiedTradingBot.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int?,
    );
  }
}

class UnifiedTradingBot {
  final String tradingbotId;
  final String? tradingbotName;
  final String? exchangeAccount;
  final String? symbol;
  final String? strategyName;
  final String status;
  final bool? isRunning;

  UnifiedTradingBot({
    required this.tradingbotId,
    this.tradingbotName,
    this.exchangeAccount,
    this.symbol,
    this.strategyName,
    required this.status,
    this.isRunning,
  });

  factory UnifiedTradingBot.fromJson(Map<String, dynamic> json) {
    return UnifiedTradingBot(
      tradingbotId: json['tradingbot_id'] as String? ?? '',
      tradingbotName: json['tradingbot_name'] as String?,
      exchangeAccount: json['exchange_account'] as String?,
      symbol: json['symbol'] as String?,
      strategyName: json['strategy_name'] as String?,
      status: json['status'] as String? ?? 'stopped',
      isRunning: json['is_running'] as bool?,
    );
  }
}

class BotOperationResponse {
  final bool success;
  final String? message;
  final String? tradingbotId;
  final String? status;

  BotOperationResponse({
    required this.success,
    this.message,
    this.tradingbotId,
    this.status,
  });

  factory BotOperationResponse.fromJson(Map<String, dynamic> json) {
    return BotOperationResponse(
      success: json['success'] as bool? ?? false,
      message: json['message'] as String?,
      tradingbotId: json['tradingbot_id'] as String?,
      status: json['status'] as String?,
    );
  }
}
