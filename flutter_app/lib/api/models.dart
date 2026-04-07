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
  /// 展示用全名（与登录 username 独立）
  final String fullName;
  final String phone;

  ManagedUserRow({
    required this.id,
    required this.username,
    required this.createdAt,
    required this.role,
    required this.linkedAccountIds,
    this.fullName = '',
    this.phone = '',
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
      fullName: (json['full_name'] as String?)?.trim() ?? '',
      phone: (json['phone'] as String?)?.trim() ?? '',
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
  /// USDT 资产余额相对期初的收益额（与 [profitAmount] 权益口径并列）
  final double cashProfitAmount;
  /// USDT 资产余额相对期初的收益率%
  final double cashProfitPercent;
  final double floatingProfit;
  final double equityUsdt;
  final double balanceUsdt;
  final String? snapshotTime;
  /// UTC 自然月月初权益（account_month_open）
  final double? monthOpenEquity;
  /// UTC 自然月月初 USDT 资产余额（account_month_open.initial_balance，OKX cashBal）
  final double? monthInitialBalance;

  /// USDT 资产余额（OKX cashBal），与可用保证金不同
  final double? cashBalance;

  /// 可用保证金（原误作 cash_balance 存入库的 availEq）
  final double? availableMargin;

  /// 占用保证金
  final double? usedMargin;

  AccountProfit({
    required this.exchangeAccount,
    required this.initialBalance,
    required this.currentBalance,
    required this.profitAmount,
    required this.profitPercent,
    this.cashProfitAmount = 0,
    this.cashProfitPercent = 0,
    required this.floatingProfit,
    required this.equityUsdt,
    double? balanceUsdt,
    this.snapshotTime,
    String? botId,
    this.monthOpenEquity,
    this.monthInitialBalance,
    this.cashBalance,
    this.availableMargin,
    this.usedMargin,
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
      cashProfitAmount: (json['cash_profit_amount'] as num?)?.toDouble() ?? 0,
      cashProfitPercent: (json['cash_profit_percent'] as num?)?.toDouble() ?? 0,
      floatingProfit: (json['floating_profit'] as num?)?.toDouble() ?? 0,
      equityUsdt: (json['equity_usdt'] as num?)?.toDouble() ?? 0,
      balanceUsdt: (json['balance_usdt'] as num?)?.toDouble(),
      snapshotTime: json['snapshot_time'] as String?,
      monthOpenEquity: (json['month_open_equity'] as num?)?.toDouble(),
      monthInitialBalance: (json['month_initial_balance'] as num?)?.toDouble() ??
          (json['month_open_cash'] as num?)?.toDouble(),
      cashBalance: (json['cash_balance'] as num?)?.toDouble(),
      availableMargin: (json['available_margin'] as num?)?.toDouble(),
      usedMargin: (json['used_margin'] as num?)?.toDouble(),
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

  /// OKX 密钥 JSON 中 api.sandbox == true（模拟盘）；与账户是否启用无关
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
      isTest: json['sandbox'] as bool? ?? false,
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
  final double cashProfitAmount;
  final double cashProfitPercent;
  final String? createdAt;
  final double? cashBalance;
  final double? availableMargin;
  final double? usedMargin;

  BotProfitSnapshot({
    required this.id,
    required this.botId,
    required this.snapshotAt,
    required this.initialBalance,
    required this.currentBalance,
    required this.equityUsdt,
    required this.profitAmount,
    required this.profitPercent,
    this.cashProfitAmount = 0,
    this.cashProfitPercent = 0,
    this.createdAt,
    this.cashBalance,
    this.availableMargin,
    this.usedMargin,
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
      cashProfitAmount: (json['cash_profit_amount'] as num?)?.toDouble() ?? 0,
      cashProfitPercent: (json['cash_profit_percent'] as num?)?.toDouble() ?? 0,
      createdAt: json['created_at'] as String?,
      cashBalance: (json['cash_balance'] as num?)?.toDouble(),
      availableMargin: (json['available_margin'] as num?)?.toDouble(),
      usedMargin: (json['used_margin'] as num?)?.toDouble(),
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

/// GET /api/tradingbots/{id}/daily-realized-pnl（北京时间自然日；平仓 uTime 归入日 + 日绩效合并，`day_basis`=asia_shanghai）。
class DailyRealizedPnlDayRow {
  DailyRealizedPnlDayRow({
    required this.day,
    required this.netPnl,
    required this.closeCount,
    this.equityChange,
    this.cashChange,
    this.pnlPct,
    this.equityBaseRealizedChain,
    this.pnlPctRealizedChain,
    this.benchmarkInstId,
    this.marketTr,
    this.efficiencyRatio,
    this.performanceUpdatedAt,
  });

  final String day;
  final double netPnl;
  final int closeCount;
  final double? equityChange;
  final double? cashChange;
  final double? pnlPct;
  final double? equityBaseRealizedChain;
  final double? pnlPctRealizedChain;
  final String? benchmarkInstId;
  final double? marketTr;
  final double? efficiencyRatio;
  final String? performanceUpdatedAt;

  factory DailyRealizedPnlDayRow.fromJson(Map<String, dynamic> json) {
    return DailyRealizedPnlDayRow(
      day: json['day'] as String? ?? '',
      netPnl: (json['net_pnl'] as num?)?.toDouble() ?? 0,
      closeCount: (json['close_count'] as num?)?.toInt() ?? 0,
      equityChange: (json['equity_change'] as num?)?.toDouble(),
      cashChange: (json['cash_change'] as num?)?.toDouble(),
      pnlPct: (json['pnl_pct'] as num?)?.toDouble(),
      equityBaseRealizedChain:
          (json['equity_base_realized_chain'] as num?)?.toDouble(),
      pnlPctRealizedChain:
          (json['pnl_pct_realized_chain'] as num?)?.toDouble(),
      benchmarkInstId: json['benchmark_inst_id'] as String?,
      marketTr: (json['market_tr'] as num?)?.toDouble(),
      efficiencyRatio: (json['efficiency_ratio'] as num?)?.toDouble(),
      performanceUpdatedAt: json['performance_updated_at'] as String?,
    );
  }
}

class DailyRealizedPnlResponse {
  DailyRealizedPnlResponse({
    required this.success,
    this.message,
    this.botId = '',
    this.year = 0,
    this.month = 0,
    this.days = const [],
    this.monthTotalPnl,
  });

  final bool success;
  final String? message;
  final String botId;
  final int year;
  final int month;
  final List<DailyRealizedPnlDayRow> days;

  /// GET daily-realized-pnl 返回的当月平仓净盈亏合计（与 [days] 汇总一致）
  final double? monthTotalPnl;

  factory DailyRealizedPnlResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['days'];
    List<DailyRealizedPnlDayRow> list = const [];
    if (raw is List) {
      list = raw
          .map(
            (e) => DailyRealizedPnlDayRow.fromJson(e as Map<String, dynamic>),
          )
          .toList();
    }
    final fromServer = (json['month_total_pnl'] as num?)?.toDouble();
    final sumDays = list.fold<double>(
      0,
      (s, e) => s + e.netPnl,
    );
    return DailyRealizedPnlResponse(
      success: json['success'] as bool? ?? false,
      message: json['message'] as String?,
      botId: json['bot_id'] as String? ?? '',
      year: (json['year'] as num?)?.toInt() ?? 0,
      month: (json['month'] as num?)?.toInt() ?? 0,
      days: list,
      monthTotalPnl: fromServer ?? (list.isNotEmpty ? sumDays : fromServer),
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
  /// 策略能效 = 当日现金增量 USDT ÷ (价格波幅 |高−低| × 1e9)。
  final double? efficiencyRatio;

  /// 权益日增量（与现金口径对称，非负增量）。
  final double? equityDeltaUsdt;
  /// 权益收益率% = 权益日增量 ÷ UTC 月初权益 × 100。
  final double? equityDeltaPct;
  final double? monthStartEquity;
  /// 权益能效 = 权益日增量 ÷ (|高−低| × 1e9)。
  final double? equityEfficiencyRatio;

  /// Wilder ATR(14)，经典 TR；与 `tr`（|H−L|）不同。
  final double? atr14;
  final double? threshold01AtrPrice;
  final double? threshold06AtrPrice;
  final double? threshold12AtrPrice;

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
    this.equityDeltaUsdt,
    this.equityDeltaPct,
    this.monthStartEquity,
    this.equityEfficiencyRatio,
    this.atr14,
    this.threshold01AtrPrice,
    this.threshold06AtrPrice,
    this.threshold12AtrPrice,
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
      equityDeltaUsdt: (json['equity_delta_usdt'] as num?)?.toDouble(),
      equityDeltaPct: (json['equity_delta_pct'] as num?)?.toDouble(),
      monthStartEquity: (json['month_start_equity'] as num?)?.toDouble(),
      equityEfficiencyRatio: (json['equity_efficiency_ratio'] as num?)?.toDouble(),
      atr14: (json['atr14'] as num?)?.toDouble(),
      threshold01AtrPrice: (json['threshold_0_1_atr_price'] as num?)?.toDouble(),
      threshold06AtrPrice: (json['threshold_0_6_atr_price'] as num?)?.toDouble(),
      threshold12AtrPrice: (json['threshold_1_2_atr_price'] as num?)?.toDouble(),
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

/// GET /api/tradingbots/{id}/open-positions-snapshots（入库的当前持仓聚合，按 snapshot_at 降序）
class OpenPositionsSnapshotRow {
  OpenPositionsSnapshotRow({
    required this.instId,
    required this.snapshotAt,
    required this.lastPx,
    required this.longPosSize,
    required this.shortPosSize,
    required this.markPx,
    required this.longUpl,
    required this.shortUpl,
    required this.totalUpl,
    required this.longAvgPx,
    required this.shortAvgPx,
  });

  final String instId;
  final String snapshotAt;
  final double lastPx;
  final double longPosSize;
  final double shortPosSize;
  final double markPx;
  final double longUpl;
  final double shortUpl;
  final double totalUpl;
  /// 该合约多头加权成本（与 AccountMgr 写入一致）
  final double longAvgPx;
  /// 该合约空头加权成本
  final double shortAvgPx;

  factory OpenPositionsSnapshotRow.fromJson(Map<String, dynamic> json) {
    return OpenPositionsSnapshotRow(
      instId: json['inst_id'] as String? ?? '',
      snapshotAt: json['snapshot_at'] as String? ?? '',
      lastPx: (json['last_px'] as num?)?.toDouble() ?? 0,
      longPosSize: (json['long_pos_size'] as num?)?.toDouble() ?? 0,
      shortPosSize: (json['short_pos_size'] as num?)?.toDouble() ?? 0,
      markPx: (json['mark_px'] as num?)?.toDouble() ?? 0,
      longUpl: (json['long_upl'] as num?)?.toDouble() ?? 0,
      shortUpl: (json['short_upl'] as num?)?.toDouble() ?? 0,
      totalUpl: (json['total_upl'] as num?)?.toDouble() ?? 0,
      longAvgPx: (json['long_avg_px'] as num?)?.toDouble() ?? 0,
      shortAvgPx: (json['short_avg_px'] as num?)?.toDouble() ?? 0,
    );
  }
}

class OpenPositionsSnapshotsResponse {
  OpenPositionsSnapshotsResponse({
    required this.success,
    this.botId = '',
    this.rows = const [],
  });

  final bool success;
  final String botId;
  final List<OpenPositionsSnapshotRow> rows;

  factory OpenPositionsSnapshotsResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['rows'];
    List<OpenPositionsSnapshotRow> list = const [];
    if (raw is List) {
      list = raw
          .map(
            (e) => OpenPositionsSnapshotRow.fromJson(
              e as Map<String, dynamic>,
            ),
          )
          .toList();
    }
    return OpenPositionsSnapshotsResponse(
      success: json['success'] as bool? ?? false,
      botId: json['bot_id'] as String? ?? '',
      rows: list,
    );
  }
}

/// 赛季：启停时间、初期权益/现金、盈利、盈利率（与 account_season.account_id 对应）
class BotSeason {
  final int id;
  final String accountId;
  final String? startedAt;
  final String? stoppedAt;
  final double initialBalance;
  final double? initialCash;
  final double? finalBalance;
  final double? finalCash;
  final double? profitAmount;
  final double? profitPercent;
  final bool? isActive;
  final int? durationSeconds;

  BotSeason({
    required this.id,
    required this.accountId,
    this.startedAt,
    this.stoppedAt,
    required this.initialBalance,
    this.initialCash,
    this.finalBalance,
    this.finalCash,
    this.profitAmount,
    this.profitPercent,
    this.isActive,
    this.durationSeconds,
  });

  factory BotSeason.fromJson(Map<String, dynamic> json) {
    return BotSeason(
      id: json['id'] as int? ?? 0,
      accountId: (json['account_id'] ?? json['bot_id']) as String? ?? '',
      startedAt: json['started_at'] as String?,
      stoppedAt: json['stopped_at'] as String?,
      initialBalance: (json['initial_balance'] as num?)?.toDouble() ?? 0,
      initialCash: (json['initial_cash'] as num?)?.toDouble(),
      finalBalance: (json['final_balance'] as num?)?.toDouble(),
      finalCash: (json['final_cash'] as num?)?.toDouble(),
      profitAmount: (json['profit_amount'] as num?)?.toDouble(),
      profitPercent: (json['profit_percent'] as num?)?.toDouble(),
      isActive: json['is_active'] as bool?,
      durationSeconds: (json['duration_seconds'] as num?)?.toInt(),
    );
  }
}

class TradingbotSeasonsResponse {
  final bool success;
  final String botId;
  final List<BotSeason> seasons;
  final int? activeSeasonCount;

  TradingbotSeasonsResponse({
    required this.success,
    required this.botId,
    required this.seasons,
    this.activeSeasonCount,
  });

  factory TradingbotSeasonsResponse.fromJson(Map<String, dynamic> json) {
    return TradingbotSeasonsResponse(
      success: json['success'] as bool? ?? false,
      botId: (json['account_id'] ?? json['bot_id']) as String? ?? '',
      seasons:
          (json['seasons'] as List<dynamic>?)
              ?.map((e) => BotSeason.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      activeSeasonCount: (json['active_season_count'] as num?)?.toInt(),
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

/// GET /api/health
class HealthResponse {
  final bool ok;
  final String? service;
  final int? accountSyncIntervalSec;
  final bool staticOnly;
  final String? processStartedAtUtc;

  HealthResponse({
    required this.ok,
    this.service,
    this.accountSyncIntervalSec,
    this.staticOnly = false,
    this.processStartedAtUtc,
  });

  factory HealthResponse.fromJson(Map<String, dynamic> json) {
    return HealthResponse(
      ok: json['ok'] as bool? ?? false,
      service: json['service'] as String?,
      accountSyncIntervalSec: (json['account_sync_interval_sec'] as num?)?.toInt(),
      staticOnly: json['static_only'] as bool? ?? false,
      processStartedAtUtc: json['process_started_at_utc'] as String?,
    );
  }
}

/// GET /api/app-version：单平台版本策略
class AppStoreVersionInfo {
  final String minVersion;
  final String latestVersion;
  final String? apkFilename;
  final String? storeUrl;

  AppStoreVersionInfo({
    this.minVersion = '',
    this.latestVersion = '',
    this.apkFilename,
    this.storeUrl,
  });

  factory AppStoreVersionInfo.fromJson(
    Map<String, dynamic>? json, {
    bool isAndroid = false,
  }) {
    if (json == null) {
      return AppStoreVersionInfo();
    }
    return AppStoreVersionInfo(
      minVersion: (json['min_version'] as String?)?.trim() ?? '',
      latestVersion: (json['latest_version'] as String?)?.trim() ?? '',
      apkFilename: isAndroid
          ? ((json['apk_filename'] as String?)?.trim())
          : null,
      storeUrl: !isAndroid
          ? ((json['store_url'] as String?)?.trim())
          : null,
    );
  }
}

/// GET /api/app-version
class AppVersionConfigResponse {
  final bool success;
  final AppStoreVersionInfo android;
  final AppStoreVersionInfo ios;

  AppVersionConfigResponse({
    required this.success,
    required this.android,
    required this.ios,
  });

  factory AppVersionConfigResponse.fromJson(Map<String, dynamic> json) {
    final a = json['android'];
    final i = json['ios'];
    return AppVersionConfigResponse(
      success: json['success'] as bool? ?? false,
      android: AppStoreVersionInfo.fromJson(
        a is Map<String, dynamic> ? a : null,
        isAndroid: true,
      ),
      ios: AppStoreVersionInfo.fromJson(
        i is Map<String, dynamic> ? i : null,
        isAndroid: false,
      ),
    );
  }
}

/// GET /api/status 中的 sync.steps 单项
class SyncStepStatus {
  final bool? ok;
  final String? error;

  SyncStepStatus({this.ok, this.error});

  factory SyncStepStatus.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return SyncStepStatus();
    }
    return SyncStepStatus(
      ok: json['ok'] as bool?,
      error: json['error'] as String?,
    );
  }
}

/// GET /api/status
class ServerStatusResponse {
  final bool success;
  final int? uptimeSeconds;
  final int? accountSyncIntervalSec;
  final String? syncDocumentation;
  final String? processStartedAtUtc;
  final String? lastRunCompletedAt;
  final String? lastLoopError;
  final Map<String, SyncStepStatus> steps;

  ServerStatusResponse({
    required this.success,
    this.uptimeSeconds,
    this.accountSyncIntervalSec,
    this.syncDocumentation,
    this.processStartedAtUtc,
    this.lastRunCompletedAt,
    this.lastLoopError,
    this.steps = const {},
  });

  factory ServerStatusResponse.fromJson(Map<String, dynamic> json) {
    final sync = json['sync'];
    String? lastAt;
    String? loopErr;
    Map<String, SyncStepStatus> stepMap = {};
    if (sync is Map<String, dynamic>) {
      lastAt = sync['last_run_completed_at'] as String?;
      loopErr = sync['last_loop_error'] as String?;
      final rawSteps = sync['steps'];
      if (rawSteps is Map) {
        rawSteps.forEach((k, v) {
          if (k is String && v is Map) {
            stepMap[k] = SyncStepStatus.fromJson(
              Map<String, dynamic>.from(v),
            );
          }
        });
      }
    }
    return ServerStatusResponse(
      success: json['success'] as bool? ?? false,
      uptimeSeconds: (json['uptime_seconds'] as num?)?.toInt(),
      accountSyncIntervalSec:
          (json['account_sync_interval_sec'] as num?)?.toInt(),
      syncDocumentation: json['sync_documentation'] as String?,
      processStartedAtUtc: json['process_started_at_utc'] as String?,
      lastRunCompletedAt: lastAt,
      lastLoopError: loopErr,
      steps: stepMap,
    );
  }
}

/// 历史仓位单行（GET .../position-history）
class PositionHistoryRow {
  final int? id;
  final String? accountId;
  final String? okxPosId;
  final String? instId;
  final String? instType;
  final String? posSide;
  final String? mgnMode;
  final String? openAvgPx;
  final String? closeAvgPx;
  final String? openMaxPos;
  final String? closeTotalPos;
  final String? pnl;
  final String? realizedPnl;
  final String? fee;
  final String? fundingFee;
  final String? closeType;
  final String? cTimeMs;
  final String? uTimeMs;
  final String? lever;
  final String? pnlRatio;
  final String? syncedAt;

  PositionHistoryRow({
    this.id,
    this.accountId,
    this.okxPosId,
    this.instId,
    this.instType,
    this.posSide,
    this.mgnMode,
    this.openAvgPx,
    this.closeAvgPx,
    this.openMaxPos,
    this.closeTotalPos,
    this.pnl,
    this.realizedPnl,
    this.fee,
    this.fundingFee,
    this.closeType,
    this.cTimeMs,
    this.uTimeMs,
    this.lever,
    this.pnlRatio,
    this.syncedAt,
  });

  static String? _dynStr(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toString();
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  factory PositionHistoryRow.fromJson(Map<String, dynamic> json) {
    return PositionHistoryRow(
      id: (json['id'] as num?)?.toInt(),
      accountId: _dynStr(json['account_id']),
      okxPosId: _dynStr(json['okx_pos_id']),
      instId: _dynStr(json['inst_id']),
      instType: _dynStr(json['inst_type']),
      posSide: _dynStr(json['pos_side']),
      mgnMode: _dynStr(json['mgn_mode']),
      openAvgPx: _dynStr(json['open_avg_px']),
      closeAvgPx: _dynStr(json['close_avg_px']),
      openMaxPos: _dynStr(json['open_max_pos']),
      closeTotalPos: _dynStr(json['close_total_pos']),
      pnl: _dynStr(json['pnl']),
      realizedPnl: _dynStr(json['realized_pnl']),
      fee: _dynStr(json['fee']),
      fundingFee: _dynStr(json['funding_fee']),
      closeType: _dynStr(json['close_type']),
      cTimeMs: _dynStr(json['c_time_ms']),
      uTimeMs: _dynStr(json['u_time_ms']),
      lever: _dynStr(json['lever']),
      pnlRatio: _dynStr(json['pnl_ratio']),
      syncedAt: _dynStr(json['synced_at']),
    );
  }
}

class PositionHistoryResponse {
  final bool success;
  final String botId;
  final List<PositionHistoryRow> rows;
  final int? nextBeforeUtime;
  final bool hasMore;

  PositionHistoryResponse({
    required this.success,
    required this.botId,
    required this.rows,
    this.nextBeforeUtime,
    this.hasMore = false,
  });

  factory PositionHistoryResponse.fromJson(Map<String, dynamic> json) {
    return PositionHistoryResponse(
      success: json['success'] as bool? ?? false,
      botId: json['bot_id'] as String? ?? '',
      rows:
          (json['rows'] as List<dynamic>?)
              ?.map(
                (e) => PositionHistoryRow.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
      nextBeforeUtime: (json['next_before_utime'] as num?)?.toInt(),
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}

/// Account_List.json 一行（管理员）
class AccountConfigRow {
  final String accountId;
  final String? accountName;
  final String? exchangeAccount;
  final String? symbol;
  final double? initialCapital;
  final String? tradingStrategy;
  final String? accountKeyFile;
  final String? scriptFile;
  final bool enabled;

  AccountConfigRow({
    required this.accountId,
    this.accountName,
    this.exchangeAccount,
    this.symbol,
    this.initialCapital,
    this.tradingStrategy,
    this.accountKeyFile,
    this.scriptFile,
    this.enabled = true,
  });

  factory AccountConfigRow.fromJson(Map<String, dynamic> json) {
    dynamic raw = json['enbaled'];
    if (raw == null && json.containsKey('enabled')) {
      raw = json['enabled'];
    }
    if (raw == null && json.containsKey('enable')) {
      raw = json['enable'];
    }
    bool ev = true;
    if (raw is bool) {
      ev = raw;
    } else if (raw is num) {
      ev = raw != 0;
    } else if (raw is String) {
      ev = !['false', '0', 'no'].contains(raw.toLowerCase());
    }
    return AccountConfigRow(
      accountId: json['account_id'] as String? ?? '',
      accountName: json['account_name'] as String?,
      exchangeAccount: json['exchange_account'] as String?,
      symbol: json['symbol'] as String?,
      initialCapital: (json['Initial_capital'] as num?)?.toDouble(),
      tradingStrategy: json['trading_strategy'] as String?,
      accountKeyFile: json['account_key_file'] as String?,
      scriptFile: json['script_file'] as String?,
      enabled: ev,
    );
  }

  Map<String, dynamic> toJsonBody() {
    return <String, dynamic>{
      'account_id': accountId,
      'account_name': accountName ?? '',
      'exchange_account': exchangeAccount ?? 'OKX',
      'symbol': symbol ?? '',
      'Initial_capital': initialCapital ?? 0,
      'trading_strategy': tradingStrategy ?? '',
      'account_key_file': accountKeyFile ?? '',
      'script_file': scriptFile ?? '',
      'enbaled': enabled,
    };
  }
}

class AdminAccountListResponse {
  final bool success;
  final List<AccountConfigRow> accounts;

  AdminAccountListResponse({required this.success, required this.accounts});

  factory AdminAccountListResponse.fromJson(Map<String, dynamic> json) {
    return AdminAccountListResponse(
      success: json['success'] as bool? ?? false,
      accounts:
          (json['accounts'] as List<dynamic>?)
              ?.map(
                (e) => AccountConfigRow.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
    );
  }
}

class AdminAccountOneResponse {
  final bool success;
  final AccountConfigRow? account;

  AdminAccountOneResponse({required this.success, this.account});

  factory AdminAccountOneResponse.fromJson(Map<String, dynamic> json) {
    final a = json['account'];
    return AdminAccountOneResponse(
      success: json['success'] as bool? ?? false,
      account: a is Map<String, dynamic>
          ? AccountConfigRow.fromJson(a)
          : null,
    );
  }
}

class SimpleMessageResponse {
  final bool success;
  final String? message;

  SimpleMessageResponse({required this.success, this.message});

  factory SimpleMessageResponse.fromJson(Map<String, dynamic> json) {
    return SimpleMessageResponse(
      success: json['success'] as bool? ?? false,
      message: json['message'] as String?,
    );
  }
}
