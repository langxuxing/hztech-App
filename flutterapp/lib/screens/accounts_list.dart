import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
import '../services/okx_public_ticker_ws.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import '../widgets/water_background.dart';
import 'account_profit_screen.dart';

/// 移动端「账户管理」汇总列表；点击进「账户收益」，数据字段与 Web「账户画像」一致（权益、现金、浮动、收益率等）。
///
/// [sharedBots] 由 [MainScreen] 下发时与账户收益页同源，避免下拉框空窗；为空则本页并行请求 `/api/tradingbots`。
class AccountsList extends StatefulWidget {
  const AccountsList({super.key, this.sharedBots = const []});

  final List<UnifiedTradingBot> sharedBots;

  @override
  State<AccountsList> createState() => _AccountsListState();
}

class _AccountsListState extends State<AccountsList> {
  final _prefs = SecurePrefs();
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

  double get _aggregateReturnPercent {
    var initialSum = 0.0;
    for (final a in _accounts) {
      initialSum += a.initialBalance;
    }
    if (initialSum <= 0) return 0;
    return (_aggregateTotalProfit / initialSum) * 100;
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

  @override
  void initState() {
    super.initState();
    _load();
    _positionsRefreshTimer = Timer.periodic(const Duration(seconds: 120), (_) {
      if (!mounted) return;
      unawaited(_refreshPositionsOnly());
    });
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
                    if (_accounts.isNotEmpty)
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
                                    label: '资产余额',
                                    value: formatUiInteger(_aggregateTotalEquity),
                                    valueColor: AppFinanceStyle.valueColor,
                                  ),
                                ),
                                Expanded(
                                  child: AppFinanceStyle.mobileSummaryStackCell(
                                    context,
                                    label: '盈利率',
                                    value: formatUiPercentLabel(pct),
                                    valueColor: pctColor,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
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
                                  vertical: kIsWeb ? 16 : 14,
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
                                            22) +
                                        2;
                                    final upl = _floatingForAccount(a);
                                    final pct = a.profitPercent;
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
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(
                                          _accountTitle(a),
                                          style:
                                              (Theme.of(
                                                        context,
                                                      ).textTheme.titleLarge ??
                                                      const TextStyle())
                                                  .copyWith(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: titleSize,
                                                    color: AppFinanceStyle
                                                        .valueColor,
                                                  ),
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceAround,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Column(
                                              children: [
                                                Text(
                                                  '余额',
                                                  style: rowLabelStyle,
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  formatUiInteger(
                                                    a.cashBalance ??
                                                        a.balanceUsdt,
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
                                                  '权益',
                                                  style: rowLabelStyle,
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  formatUiInteger(a.equityUsdt),
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
                                                  '收益率',
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
