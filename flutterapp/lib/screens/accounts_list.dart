import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/client.dart';
import '../constants/poll_intervals.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
import '../services/okx_public_ticker_ws.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import '../widgets/water_background.dart';
import 'account_profit_screen.dart';

/// 列表页金额口径：与 [WebDashboardScreen] 一致，默认权益；可切换为 USDT 现金余额及相关盈亏。
enum _AccountsListBasis { equity, cash }

/// 移动端「账户管理」汇总列表；点击进「账户收益」，数据字段与 Web「账户画像」一致（权益、现金、浮动、收益率等）。
///
/// [sharedBots] 由 [MainScreen] 下发时与账户收益页同源，避免下拉框空窗；为空则本页并行请求 `/api/tradingbots`。
///
/// [periodicRefreshActive] 为 false 时不轮询持仓（例如 [MainScreen] 底栏非「账户总览」时）。
class AccountsList extends StatefulWidget {
  const AccountsList({
    super.key,
    this.sharedBots = const [],
    this.periodicRefreshActive = true,
  });

  final List<UnifiedTradingBot> sharedBots;
  final bool periodicRefreshActive;

  @override
  State<AccountsList> createState() => _AccountsListState();
}

class _AccountsListState extends State<AccountsList> {
  final _prefs = SecurePrefs();

  /// 默认权益口径；可切换现金余额口径（与 Web 总览一致）。
  _AccountsListBasis _basis = _AccountsListBasis.equity;

  List<AccountProfit> _accounts = [];

  /// 仅当 [widget.sharedBots] 为空时由本页拉取填充。
  List<UnifiedTradingBot> _fetchedBots = [];
  bool _loading = true;
  String? _error;

  /// 各 bot 的交易所持仓（与 /api/tradingbots/:id/positions 一致）；用于列表行浮动盈亏动态计算。
  final Map<String, List<OkxPosition>> _positionsByBot = {};

  /// 单合约持仓时，按 instId 订阅公共 ticker 的最近价（与 [AccountProfitScreen] 一致）。
  final Map<String, OkxPublicTickerWs> _tickerByInstId = {};
  final Map<String, StreamSubscription<double>> _tickerSubsByInstId = {};
  final Map<String, double> _liveLastPxByInstId = {};
  Timer? _positionsRefreshTimer;

  List<UnifiedTradingBot> get _effectiveBots =>
      widget.sharedBots.isNotEmpty ? widget.sharedBots : _fetchedBots;

  UnifiedTradingBot? _botFor(String botId) {
    if (botId.isEmpty) return null;
    for (final b in _effectiveBots) {
      if (b.tradingbotId == botId) return b;
    }
    return null;
  }

  /// 与 Web 顶栏账户顺序一致：按 tradingbots 列表排序，其余账户排在后面。
  List<AccountProfit> get _orderedAccounts {
    final list = List<AccountProfit>.from(_accounts);
    final order = _effectiveBots.map((b) => b.tradingbotId).toList();
    if (order.isEmpty) return list;
    int rank(String id) {
      final i = order.indexOf(id);
      return i < 0 ? 1 << 30 : i;
    }

    list.sort((a, b) => rank(a.botId).compareTo(rank(b.botId)));
    return list;
  }

  /// 与 Web「账户总览」汇总条一致：期末资产等为各账户加总；盈利率 = 总盈利 ÷ 总期初 × 100。
  double get _aggregateInitialSum =>
      _accounts.fold<double>(0, (s, a) => s + a.initialBalance);

  double get _aggregateTotalEquity =>
      _accounts.fold<double>(0, (s, a) => s + a.equityUsdt);

  double get _aggregateTotalProfit =>
      _accounts.fold<double>(0, (s, a) => s + a.profitAmount);

  double get _aggregateTotalCash =>
      _accounts.fold<double>(0, (s, a) => s + (a.cashBalance ?? a.balanceUsdt));

  double get _aggregateTotalCashProfit =>
      _accounts.fold<double>(0, (s, a) => s + a.cashProfitAmount);

  double get _aggregateReturnPercent {
    final initialSum = _aggregateInitialSum;
    if (initialSum <= 0) return 0;
    if (_basis == _AccountsListBasis.equity) {
      return (_aggregateTotalProfit / initialSum) * 100;
    }
    return (_aggregateTotalCashProfit / initialSum) * 100;
  }

  /// 优先显示交易账户名称，不将「OKX」等交易所名作为主标题。
  String _accountTitle(AccountProfit a) {
    final bot = _botFor(a.botId);
    final name = bot?.tradingbotName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final ex = a.exchangeAccount.trim();
    if (ex.isNotEmpty && ex.toUpperCase() != 'OKX') return ex;
    return a.botId.isNotEmpty ? a.botId : '—';
  }

  static double _dynUplFor(OkxPosition p, double last) {
    final mark = p.markPx;
    final avg = p.avgPx;
    final denom = mark - avg;
    if (denom.abs() < 1e-12) return p.upl;
    return p.upl * (last - avg) / denom;
  }

  static double _totalDynUpl(Iterable<OkxPosition> ps, double last) =>
      ps.fold<double>(0, (s, p) => s + _dynUplFor(p, last));

  static double _singleInstQuotePx(List<OkxPosition> positions) {
    for (final p in positions) {
      final d = p.displayPrice;
      if (d > 0) return d;
    }
    for (final p in positions) {
      if (p.markPx > 0) return p.markPx;
    }
    return 0;
  }

  /// 与账户收益页「浮动盈亏」一致：单合约时用 ticker 价缩放 upl；否则用各腿 upl 之和；无持仓数据时回落快照字段。
  double _floatingForAccount(AccountProfit a) {
    final botId = a.botId.trim();
    if (botId.isEmpty) return a.floatingProfit;
    final positions = _positionsByBot[botId] ?? const <OkxPosition>[];
    if (positions.isEmpty) return a.floatingProfit;
    final singleInst =
        positions.isNotEmpty &&
        positions
                .map((p) => p.instId)
                .where((e) => e.isNotEmpty)
                .toSet()
                .length ==
            1;
    final curPx = singleInst && positions.isNotEmpty
        ? (_liveLastPxByInstId[positions.first.instId] ??
              _singleInstQuotePx(positions))
        : 0.0;
    if (singleInst && curPx > 0) {
      return _totalDynUpl(positions, curPx);
    }
    return positions.fold<double>(0, (s, p) => s + p.upl);
  }

  void _disposeAllTickers() {
    for (final sub in _tickerSubsByInstId.values) {
      sub.cancel();
    }
    _tickerSubsByInstId.clear();
    for (final ws in _tickerByInstId.values) {
      ws.dispose();
    }
    _tickerByInstId.clear();
    _liveLastPxByInstId.clear();
  }

  void _syncTickerSubscriptions() {
    final needed = <String>{};
    for (final entry in _positionsByBot.entries) {
      final ps = entry.value;
      if (ps.isEmpty) continue;
      final ids = ps.map((p) => p.instId).where((e) => e.isNotEmpty).toSet();
      if (ids.length == 1) needed.add(ids.first);
    }
    for (final inst in _tickerByInstId.keys.toList()) {
      if (!needed.contains(inst)) {
        _tickerSubsByInstId[inst]?.cancel();
        _tickerSubsByInstId.remove(inst);
        _tickerByInstId[inst]?.dispose();
        _tickerByInstId.remove(inst);
        _liveLastPxByInstId.remove(inst);
      }
    }
    for (final inst in needed) {
      if (_tickerByInstId.containsKey(inst)) continue;
      final ws = OkxPublicTickerWs();
      _tickerByInstId[inst] = ws;
      ws.subscribe(inst);
      final stream = ws.priceStream;
      if (stream != null) {
        _tickerSubsByInstId[inst] = stream.listen((px) {
          if (!mounted) return;
          setState(() => _liveLastPxByInstId[inst] = px);
        });
      }
    }
  }

  Future<void> _fetchPositionsForAccounts(ApiClient api) async {
    final ids = <String>[];
    final seen = <String>{};
    for (final a in _accounts) {
      final id = a.botId.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      ids.add(id);
    }
    if (ids.isEmpty) {
      _disposeAllTickers();
      if (!mounted) return;
      setState(() => _positionsByBot.clear());
      return;
    }
    final results = await Future.wait(
      ids.map((id) => api.getTradingbotPositions(id)),
    );
    if (!mounted) return;
    setState(() {
      _positionsByBot
        ..clear()
        ..addEntries(
          List.generate(
            ids.length,
            (i) => MapEntry(ids[i], results[i].positions),
          ),
        );
    });
    _syncTickerSubscriptions();
  }

  Future<void> _refreshPositionsOnly() async {
    if (!mounted || _loading || _accounts.isEmpty) return;
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      await _fetchPositionsForAccounts(api);
    } catch (_) {
      // 后台轮询失败不打扰主流程
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      late final AccountProfitResponse profitResp;
      List<UnifiedTradingBot> bots = List.from(widget.sharedBots);
      if (widget.sharedBots.isEmpty) {
        final pair = await Future.wait([
          api.getAccountProfit(),
          api.getTradingBots(),
        ]);
        profitResp = pair[0] as AccountProfitResponse;
        bots = (pair[1] as TradingBotsResponse).botList;
      } else {
        profitResp = await api.getAccountProfit();
      }
      if (!mounted) return;
      setState(() {
        _accounts = profitResp.accounts ?? [];
        _fetchedBots = bots;
        _loading = false;
      });
      try {
        await _fetchPositionsForAccounts(api);
      } catch (_) {
        // 持仓接口失败时仍展示 account-profit 汇总
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  static const _barBg = AppFinanceStyle.backgroundDark;
  static const _barTextColor = AppFinanceStyle.valueColor;

  void _syncPositionsRefreshTimer() {
    _positionsRefreshTimer?.cancel();
    _positionsRefreshTimer = null;
    if (!widget.periodicRefreshActive) return;
    _positionsRefreshTimer = Timer.periodic(PollIntervals.slowPoll, (_) {
      if (!mounted) return;
      unawaited(_refreshPositionsOnly());
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
    _syncPositionsRefreshTimer();
  }

  @override
  void didUpdateWidget(covariant AccountsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.periodicRefreshActive != widget.periodicRefreshActive) {
      _syncPositionsRefreshTimer();
    }
  }

  @override
  void dispose() {
    _positionsRefreshTimer?.cancel();
    _disposeAllTickers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '账户管理',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(
            color: _barTextColor,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: _barBg,
        foregroundColor: _barTextColor,
        surfaceTintColor: Colors.transparent,
      ),
      body: WaterBackground(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading && _accounts.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _accounts.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          children: [
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppFinanceStyle.textDefault,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: _load,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : ListView(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    kIsWeb
                        ? 24 + AppFinanceStyle.webSummaryTitleSpacing
                        : 24,
                    24,
                    32,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1680),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                    if (_accounts.isNotEmpty) ...[
                      Row(
                        children: [
                          const Spacer(),
                          SegmentedButton<_AccountsListBasis>(
                            style: ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(
                                value: _AccountsListBasis.equity,
                                label: Text('权益'),
                                tooltip: '权益金额口径',
                              ),
                              ButtonSegment(
                                value: _AccountsListBasis.cash,
                                label: Text('现金余额'),
                                tooltip: '现金余额口径',
                              ),
                            ],
                            selected: {_basis},
                            onSelectionChanged: (s) {
                              if (s.isEmpty) return;
                              setState(() => _basis = s.first);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      FinanceCard(
                        padding: kIsWeb
                            ? AppFinanceStyle.webSummaryStripPadding
                            : AppFinanceStyle.mobileSummaryStripPadding,
                        child: Builder(
                          builder: (context) {
                            final pct = _aggregateReturnPercent;
                            final pctColor = pct >= 0
                                ? AppFinanceStyle.textProfit
                                : AppFinanceStyle.textLoss;
                            final midLabel = _basis == _AccountsListBasis.equity
                                ? '总权益'
                                : '总现金';
                            final midValue = _basis == _AccountsListBasis.equity
                                ? _aggregateTotalEquity
                                : _aggregateTotalCash;
                            final pctLabel = _basis == _AccountsListBasis.equity
                                ? '平均收益率'
                                : '平均现金收益率';
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: AppFinanceStyle.mobileSummaryStackCell(
                                    context,
                                    label: '月初',
                                    value: formatUiInteger(_aggregateInitialSum),
                                    valueColor: AppFinanceStyle.valueColor,
                                  ),
                                ),
                                Expanded(
                                  child: AppFinanceStyle.mobileSummaryStackCell(
                                    context,
                                    label: midLabel,
                                    value: formatUiInteger(midValue),
                                    valueColor: AppFinanceStyle.valueColor,
                                  ),
                                ),
                                Expanded(
                                  child: AppFinanceStyle.mobileSummaryStackCell(
                                    context,
                                    label: pctLabel,
                                    value: formatUiPercentLabel(pct),
                                    valueColor: pctColor,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                    if (_accounts.isNotEmpty) const SizedBox(height: 24),
                    Text(
                      '账户概览',
                      style: AppFinanceStyle.accountProfitOverviewHeadingStyle(
                        context,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (_accounts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            '暂无账户数据',
                            style: AppFinanceStyle.labelTextStyle(context),
                          ),
                        ),
                      )
                    else
                      ..._orderedAccounts.map(
                        (a) => Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (ctx) => AccountProfitScreen(
                                      sharedBots: _effectiveBots,
                                      initialBotId: a.botId.isNotEmpty
                                          ? a.botId
                                          : null,
                                    ),
                                  ),
                                );
                              },
                              borderRadius: BorderRadius.circular(
                                AppFinanceStyle.cardRadius,
                              ),
                              child: FinanceCard(
                                padding: EdgeInsets.symmetric(
                                  horizontal: kIsWeb ? 20 : 16,
                                  // 账户概览卡片竖直内边距再 +20%
                                  vertical: kIsWeb ? 25.3 : 22.2,
                                ),
                                child: Builder(
                                  builder: (context) {
                                    final rowLabelStyle = Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: AppFinanceStyle.labelColor,
                                        );
                                    final titleSize =
                                        (Theme.of(
                                              context,
                                            ).textTheme.titleLarge?.fontSize ??
                                            22) ;
                                    final upl = _floatingForAccount(a);
                                    final pctEquity = a.profitPercent;
                                    final pctCash = a.cashProfitPercent;
                                    final pct = _basis == _AccountsListBasis.equity
                                        ? pctEquity
                                        : pctCash;
                                    final currentLabel =
                                        _basis == _AccountsListBasis.equity
                                        ? '当前权益'
                                        : '当前现金';
                                    final currentValue =
                                        _basis == _AccountsListBasis.equity
                                        ? a.equityUsdt
                                        : (a.cashBalance ?? a.balanceUsdt);
                                    final returnLabel =
                                        _basis == _AccountsListBasis.equity
                                        ? '收益率'
                                        : '现金收益率';
                                    TextStyle metricValue(Color c) =>
                                        (Theme.of(
                                                  context,
                                                ).textTheme.titleMedium ??
                                                const TextStyle())
                                            .copyWith(
                                              color: c,
                                              fontWeight: FontWeight.bold,
                                              fontSize: titleSize,
                                            );
                                    return ConstrainedBox(
                                      constraints: BoxConstraints(
                                        minHeight: kIsWeb ? 128 : 110,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            _accountTitle(a),
                                            style:
                                                (Theme.of(
                                                          context,
                                                        )
                                                            .textTheme
                                                            .titleLarge ??
                                                        const TextStyle())
                                                    .copyWith(
                                                      fontWeight: FontWeight.w800,
                                                      fontSize: titleSize,
                                                      color: AppFinanceStyle
                                                          .valueColor,
                                                    ),
                                          ),
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceAround,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            children: [
                                            Column(
                                              children: [
                                                Text(
                                                  '月初',
                                                  style: rowLabelStyle,
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  formatUiInteger(
                                                    a.initialBalance,
                                                  ),
                                                  style: metricValue(
                                                    AppFinanceStyle
                                                        .profitGreenEnd,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                            Column(
                                              children: [
                                                Text(
                                                  currentLabel,
                                                  style: rowLabelStyle,
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  formatUiInteger(currentValue),
                                                  style: metricValue(
                                                    AppFinanceStyle
                                                        .profitGreenEnd,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                            Column(
                                              children: [
                                                Text(
                                                  '浮亏',
                                                  style: rowLabelStyle,
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  formatUiSignedInteger(upl),
                                                  style: metricValue(
                                                    upl >= 0
                                                        ? AppFinanceStyle
                                                              .profitGreenEnd
                                                        : AppFinanceStyle
                                                              .textLoss,
                                                  ),
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                            Column(
                                              children: [
                                                Text(
                                                  returnLabel,
                                                  style: rowLabelStyle,
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  formatUiPercentLabel(pct),
                                                  style: metricValue(
                                                    pct >= 0
                                                        ? AppFinanceStyle
                                                              .profitGreenEnd
                                                        : AppFinanceStyle
                                                              .textLoss,
                                                  ),
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
