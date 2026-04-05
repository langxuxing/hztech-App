/// 登录接口响应
class LoginResponse {
  final bool success;
  final String? token;
  final String? message;
  final String? role;
  final List<String> linkedAccountIds;

  LoginResponse({
    required this.success,
    this.token,
    this.message,
    this.role,
    this.linkedAccountIds = const [],
  });

  factory LoginResponse.fromJson(Map<String, dynamic> json) {
    final rawLinks = json['linked_account_ids'];
    List<String> links = const [];
    if (rawLinks is List) {
      links = rawLinks.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    }
    return LoginResponse(
      success: json['success'] as bool? ?? false,
      token: json['token'] as String?,
      message: json['message'] as String?,
      role: json['role'] as String?,
      linkedAccountIds: links,
    );
  }
}

/// GET /api/me
class MeResponse {
  final bool success;
  final String? username;
  final String? role;
  final List<String> linkedAccountIds;

  MeResponse({
    required this.success,
    this.username,
    this.role,
    this.linkedAccountIds = const [],
  });

  factory MeResponse.fromJson(Map<String, dynamic> json) {
    final rawLinks = json['linked_account_ids'];
    List<String> links = const [];
    if (rawLinks is List) {
      links = rawLinks.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    }
    return MeResponse(
      success: json['success'] as bool? ?? false,
      username: json['username'] as String?,
      role: json['role'] as String?,
      linkedAccountIds: links,
    );
  }
}

/// 用户管理列表项（与 /api/users 对齐）
class ManagedUserRow {
  final int id;
  final String username;
  final String createdAt;
  final String role;
  final List<String> linkedAccountIds;

  ManagedUserRow({
    required this.id,
    required this.username,
    required this.createdAt,
    required this.role,
    required this.linkedAccountIds,
  });

  factory ManagedUserRow.fromJson(Map<String, dynamic> json) {
    final rawLinks = json['linked_account_ids'];
    List<String> links = const [];
    if (rawLinks is List) {
      links = rawLinks.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    }
    return ManagedUserRow(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      role: (json['role'] as String? ?? 'trader').toLowerCase(),
      linkedAccountIds: links,
    );
  }
}

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
  final String botId;
  final String exchangeAccount;
  final double initialBalance;
  final double currentBalance;
  final double profitAmount;
  final double profitPercent;
  final double floatingProfit;
  final double equityUsdt;
  final double balanceUsdt;
  final String? snapshotTime;

  AccountProfit({
    required this.exchangeAccount,
    required this.initialBalance,
    required this.currentBalance,
    required this.profitAmount,
    required this.profitPercent,
    required this.floatingProfit,
    required this.equityUsdt,
    double? balanceUsdt,
    this.snapshotTime,
    String? botId,
  }) : balanceUsdt = balanceUsdt ?? currentBalance,
       botId = botId ?? '';

  factory AccountProfit.fromJson(Map<String, dynamic> json) {
    return AccountProfit(
      botId: json['bot_id'] as String?,
      exchangeAccount: json['exchange_account'] as String? ?? '',
      initialBalance: (json['initial_balance'] as num?)?.toDouble() ?? 0,
      currentBalance: (json['current_balance'] as num?)?.toDouble() ?? 0,
      profitAmount: (json['profit_amount'] as num?)?.toDouble() ?? 0,
      profitPercent: (json['profit_percent'] as num?)?.toDouble() ?? 0,
      floatingProfit: (json['floating_profit'] as num?)?.toDouble() ?? 0,
      equityUsdt: (json['equity_usdt'] as num?)?.toDouble() ?? 0,
      balanceUsdt: (json['balance_usdt'] as num?)?.toDouble(),
      snapshotTime: json['snapshot_time'] as String?,
    );
  }
}

/// 交易账户列表（与后端 /api/tradingbots 一致）
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

  /// 是否支持在 App 中启停（仅部分 bot 如 simpleserver 可管控）
  final bool canControl;

  /// 是否为测试账号
  final bool isTest;

  UnifiedTradingBot({
    required this.tradingbotId,
    this.tradingbotName,
    this.exchangeAccount,
    this.symbol,
    this.strategyName,
    required this.status,
    this.isRunning,
    this.canControl = false,
    this.isTest = false,
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
      canControl: json['can_control'] as bool? ?? false,
      isTest: json['enabled'] as bool? ?? false,
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

/// 机器人盈利快照（收益曲线数据点）
class BotProfitSnapshot {
  final int id;
  final String botId;
  final String snapshotAt;
  final double initialBalance;
  final double currentBalance;
  final double equityUsdt;
  final double profitAmount;
  final double profitPercent;
  final String? createdAt;

  BotProfitSnapshot({
    required this.id,
    required this.botId,
    required this.snapshotAt,
    required this.initialBalance,
    required this.currentBalance,
    required this.equityUsdt,
    required this.profitAmount,
    required this.profitPercent,
    this.createdAt,
  });

  factory BotProfitSnapshot.fromJson(Map<String, dynamic> json) {
    return BotProfitSnapshot(
      id: json['id'] as int? ?? 0,
      botId: json['bot_id'] as String? ?? '',
      snapshotAt: json['snapshot_at'] as String? ?? '',
      initialBalance: (json['initial_balance'] as num?)?.toDouble() ?? 0,
      currentBalance: (json['current_balance'] as num?)?.toDouble() ?? 0,
      equityUsdt: (json['equity_usdt'] as num?)?.toDouble() ?? 0,
      profitAmount: (json['profit_amount'] as num?)?.toDouble() ?? 0,
      profitPercent: (json['profit_percent'] as num?)?.toDouble() ?? 0,
      createdAt: json['created_at'] as String?,
    );
  }
}

class BotProfitHistoryResponse {
  final bool success;
  final String botId;
  final List<BotProfitSnapshot> snapshots;

  BotProfitHistoryResponse({
    required this.success,
    required this.botId,
    required this.snapshots,
  });

  factory BotProfitHistoryResponse.fromJson(Map<String, dynamic> json) {
    return BotProfitHistoryResponse(
      success: json['success'] as bool? ?? false,
      botId: json['bot_id'] as String? ?? '',
      snapshots:
          (json['snapshots'] as List<dynamic>?)
              ?.map(
                (e) => BotProfitSnapshot.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
    );
  }
}

/// 策略效能：每日波动率、现金收益率%（分母多为 UTC 自然月月初资金）、策略能效。
class StrategyDailyEfficiencyRow {
  final String day;
  final double open;
  final double high;
  final double low;
  final double close;
  /// 服务端字段名仍为 tr，数值为当日 |high−low|（非负）。
  final double tr;
  /// 每日波动率% = |高−低| / 收盘 × 100。
  final double? trPct;
  final double? sodCash;
  final double? eodCash;
  final double? cashDeltaUsdt;
  /// 现金收益率% = 当日现金增量 USDT ÷ 当 UTC 自然月月初资金 × 100（无月初表时用当日日初 sod）。
  final double? cashDeltaPct;
  /// 有值表示收益率分母为 UTC 月初资金；null 表示用了当日 sod 回退。
  final double? monthStartCash;
  /// 策略能效 = 当日现金增量 USDT ÷ 价格波幅 |高−低| × 1e-7。
  final double? efficiencyRatio;

  StrategyDailyEfficiencyRow({
    required this.day,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.tr,
    this.trPct,
    this.sodCash,
    this.eodCash,
    this.cashDeltaUsdt,
    this.cashDeltaPct,
    this.monthStartCash,
    this.efficiencyRatio,
  });

  factory StrategyDailyEfficiencyRow.fromJson(Map<String, dynamic> json) {
    return StrategyDailyEfficiencyRow(
      day: json['day'] as String? ?? '',
      open: (json['open'] as num?)?.toDouble() ?? 0,
      high: (json['high'] as num?)?.toDouble() ?? 0,
      low: (json['low'] as num?)?.toDouble() ?? 0,
      close: (json['close'] as num?)?.toDouble() ?? 0,
      tr: (json['tr'] as num?)?.toDouble() ?? 0,
      trPct: (json['tr_pct'] as num?)?.toDouble(),
      sodCash: (json['sod_cash'] as num?)?.toDouble(),
      eodCash: (json['eod_cash'] as num?)?.toDouble(),
      cashDeltaUsdt: (json['cash_delta_usdt'] as num?)?.toDouble(),
      cashDeltaPct: (json['cash_delta_pct'] as num?)?.toDouble(),
      monthStartCash: (json['month_start_cash'] as num?)?.toDouble(),
      efficiencyRatio: (json['efficiency_ratio'] as num?)?.toDouble(),
    );
  }
}

class StrategyDailyEfficiencyResponse {
  final bool success;
  final String? message;
  final String botId;
  final String instId;
  final String dayBasis;
  final String cashBasis;
  final List<StrategyDailyEfficiencyRow> rows;

  StrategyDailyEfficiencyResponse({
    required this.success,
    this.message,
    required this.botId,
    required this.instId,
    required this.dayBasis,
    required this.cashBasis,
    required this.rows,
  });

  factory StrategyDailyEfficiencyResponse.fromJson(Map<String, dynamic> json) {
    return StrategyDailyEfficiencyResponse(
      success: json['success'] as bool? ?? false,
      message: json['message'] as String?,
      botId: json['bot_id'] as String? ?? '',
      instId: json['inst_id'] as String? ?? '',
      dayBasis: json['day_basis'] as String? ?? 'utc',
      cashBasis: json['cash_basis'] as String? ?? 'none',
      rows:
          (json['rows'] as List<dynamic>?)
              ?.map(
                (e) => StrategyDailyEfficiencyRow.fromJson(
                  e as Map<String, dynamic>,
                ),
              )
              .toList() ??
          [],
    );
  }
}

/// OKX 持仓（数量、持仓成本 avgPx、当前价 markPx/lastPx、动态盈亏 upl）
class OkxPosition {
  final String instId;
  final double pos;
  final String posSide;
  final double avgPx;
  final double markPx;

  /// 实时最新价（从 OKX ticker 拉取），若无则用 markPx
  final double? lastPx;
  final double upl;

  OkxPosition({
    required this.instId,
    required this.pos,
    required this.posSide,
    required this.avgPx,
    required this.markPx,
    this.lastPx,
    required this.upl,
  });

  double get displayPrice => lastPx ?? markPx;

  factory OkxPosition.fromJson(Map<String, dynamic> json) {
    final markPx = (json['mark_px'] as num?)?.toDouble() ?? 0.0;
    final lastPx = (json['last_px'] as num?)?.toDouble();
    return OkxPosition(
      instId: json['inst_id'] as String? ?? '',
      pos: (json['pos'] as num?)?.toDouble() ?? 0,
      posSide: json['pos_side'] as String? ?? 'net',
      avgPx: (json['avg_px'] as num?)?.toDouble() ?? 0,
      markPx: markPx,
      lastPx: lastPx,
      upl: (json['upl'] as num?)?.toDouble() ?? 0,
    );
  }
}

class OkxPositionsResponse {
  final bool success;
  final List<OkxPosition> positions;

  /// 当 OKX 请求失败时后端返回的提示（如配置或网络问题）
  final String? positionsError;

  /// 1010 等场景后端附带的调试信息（出口 IP、配置文件名、脱敏 key）
  final Map<String, dynamic>? okxDebug;

  OkxPositionsResponse({
    required this.success,
    required this.positions,
    this.positionsError,
    this.okxDebug,
  });

  factory OkxPositionsResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['okx_debug'];
    Map<String, dynamic>? okxDebug;
    if (raw is Map<String, dynamic>) {
      okxDebug = raw;
    } else if (raw is Map) {
      okxDebug = Map<String, dynamic>.from(raw);
    }
    return OkxPositionsResponse(
      success: json['success'] as bool? ?? false,
      positions:
          (json['positions'] as List<dynamic>?)
              ?.map((e) => OkxPosition.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      positionsError: json['positions_error'] as String?,
      okxDebug: okxDebug,
    );
  }
}

/// 赛季：启停时间、初期金额、盈利、盈利率
class BotSeason {
  final int id;
  final String botId;
  final String? startedAt;
  final String? stoppedAt;
  final double initialBalance;
  final double? finalBalance;
  final double? profitAmount;
  final double? profitPercent;

  BotSeason({
    required this.id,
    required this.botId,
    this.startedAt,
    this.stoppedAt,
    required this.initialBalance,
    this.finalBalance,
    this.profitAmount,
    this.profitPercent,
  });

  factory BotSeason.fromJson(Map<String, dynamic> json) {
    return BotSeason(
      id: json['id'] as int? ?? 0,
      botId: json['bot_id'] as String? ?? '',
      startedAt: json['started_at'] as String?,
      stoppedAt: json['stopped_at'] as String?,
      initialBalance: (json['initial_balance'] as num?)?.toDouble() ?? 0,
      finalBalance: (json['final_balance'] as num?)?.toDouble(),
      profitAmount: (json['profit_amount'] as num?)?.toDouble(),
      profitPercent: (json['profit_percent'] as num?)?.toDouble(),
    );
  }
}

class TradingbotSeasonsResponse {
  final bool success;
  final String botId;
  final List<BotSeason> seasons;

  TradingbotSeasonsResponse({
    required this.success,
    required this.botId,
    required this.seasons,
  });

  factory TradingbotSeasonsResponse.fromJson(Map<String, dynamic> json) {
    return TradingbotSeasonsResponse(
      success: json['success'] as bool? ?? false,
      botId: json['bot_id'] as String? ?? '',
      seasons:
          (json['seasons'] as List<dynamic>?)
              ?.map((e) => BotSeason.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// 策略启停事件（与 GET /api/tradingbots/{id}/tradingbot-events 一致）
class StrategyEvent {
  final int id;
  final String botId;
  final String eventType;
  final String? triggerType;
  final String? username;
  final String createdAt;

  StrategyEvent({
    required this.id,
    required this.botId,
    required this.eventType,
    this.triggerType,
    this.username,
    required this.createdAt,
  });

  factory StrategyEvent.fromJson(Map<String, dynamic> json) {
    return StrategyEvent(
      id: json['id'] as int? ?? 0,
      botId: json['bot_id'] as String? ?? '',
      eventType: json['event_type'] as String? ?? '',
      triggerType: json['trigger_type'] as String?,
      username: json['username'] as String?,
      createdAt: json['created_at'] as String? ?? '',
    );
  }
}

class TradingbotEventsResponse {
  final bool success;
  final String botId;
  final List<StrategyEvent> events;

  TradingbotEventsResponse({
    required this.success,
    required this.botId,
    required this.events,
  });

  factory TradingbotEventsResponse.fromJson(Map<String, dynamic> json) {
    return TradingbotEventsResponse(
      success: json['success'] as bool? ?? false,
      botId: json['bot_id'] as String? ?? '',
      events:
          (json['events'] as List<dynamic>?)
              ?.map((e) => StrategyEvent.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
