import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../utils/network_error_message.dart';
import '../utils/number_display_format.dart';
import '../widgets/water_background.dart';

/// 移动端「策略盈利」：按机器人列表展示月初 / 资产余额 / 盈利率与收益曲线（不含策略启停）。
/// 数据与 [TradingBotControl] 同源，界面仅保留盈利相关展示。
class AccountProfitDetailScreen extends StatefulWidget {
  const AccountProfitDetailScreen({super.key, this.embedInShell = false});

  /// 嵌入 Web 主导航壳时不显示本页 [AppBar]，避免与壳重复。
  final bool embedInShell;

  @override
  State<AccountProfitDetailScreen> createState() =>
      _AccountProfitDetailScreenState();
}

class _AccountProfitDetailScreenState extends State<AccountProfitDetailScreen> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _list = [];
  List<AccountProfit> _accounts = [];
  Map<String, List<BotProfitSnapshot>> _profitHistory = {};
  bool _loading = true;
  String? _error;
  /// 机器人列表已加载但收益/曲线请求失败时展示（避免静默失败）。
  String? _detailError;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _detailError = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final botsResp = await api.getTradingBots();
      final bots = botsResp.botList;
      if (!mounted) return;
      setState(() {
        _list = bots;
        _loading = false;
      });
      try {
        final profitFuture = api.getAccountProfit();
        final historyFutures = bots.map(
          (b) => api.getBotProfitHistory(b.tradingbotId),
        );
        final profitResp = await profitFuture;
        if (!mounted) return;
        final accounts = profitResp.accounts ?? [];
        final historyResults = await Future.wait(historyFutures);
        if (!mounted) return;
        final Map<String, List<BotProfitSnapshot>> history = {};
        for (var i = 0; i < bots.length && i < historyResults.length; i++) {
          final hr = historyResults[i];
          if (hr.snapshots.isNotEmpty) {
            history[bots[i].tradingbotId] = hr.snapshots;
          }
        }
        setState(() {
          _accounts = accounts;
          _profitHistory = history;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _detailError = '收益与曲线加载失败：${friendlyNetworkError(e)}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyNetworkError(e);
        _loading = false;
      });
    }
  }

  AccountProfit? _accountForBot(UnifiedTradingBot bot, int index) {
    if (_accounts.isEmpty) return null;
    for (final a in _accounts) {
      if (a.botId == bot.tradingbotId) return a;
    }
    if (index >= 0 && index < _accounts.length) return _accounts[index];
    final ex = bot.exchangeAccount;
    if (ex != null && ex.isNotEmpty) {
      for (final a in _accounts) {
        if (a.exchangeAccount == ex) return a;
      }
    }
    return _accounts.isNotEmpty ? _accounts.first : null;
  }

  String _fmt(double v) => formatUiInteger(v);

  static const _barBg = AppFinanceStyle.backgroundDark;
  static const _barTextColor = AppFinanceStyle.valueColor;
  static const _cardLabelColor = AppFinanceStyle.labelColor;
  static const _cardNumberColor = AppFinanceStyle.profitGreenEnd;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: widget.embedInShell
          ? null
          : AppBar(
              title: Text(
                '策略盈利',
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
          child: _loading && _list.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _list.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _list.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.insights_outlined,
                        size: 64,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '暂无交易账户',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '请检查后端 Account_List.json 或下拉刷新',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                  itemCount:
                      _list.length + (_detailError != null && _list.isNotEmpty ? 1 : 0),
                  itemBuilder: (context, index) {
                    final hasBanner =
                        _detailError != null && _list.isNotEmpty;
                    if (hasBanner) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            _detailError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 14,
                            ),
                          ),
                        );
                      }
                    }
                    final listIndex =
                        hasBanner ? index - 1 : index;
                    final bot = _list[listIndex];
                    final account = _accountForBot(bot, listIndex);
                    final snapshots = _profitHistory[bot.tradingbotId] ?? [];
                    final topMetricStyle = AppFinanceStyle.valueTextStyle(
                      context,
                      fontSize: AppFinanceStyle.mobileSummaryValueFontSize(
                        context,
                      ),
                    ).copyWith(color: _cardNumberColor);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: FinanceCard(
                        padding: AppFinanceStyle.mobileSummaryStripPadding,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              bot.tradingbotName ??
                                                  bot.tradingbotId,
                                              style:
                                                  (Theme.of(context)
                                                              .textTheme
                                                              .titleLarge ??
                                                          const TextStyle())
                                                      .copyWith(
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        fontSize:
                                                            (Theme.of(context)
                                                                    .textTheme
                                                                    .titleLarge
                                                                    ?.fontSize ??
                                                                22) +
                                                            2,
                                                        color: AppFinanceStyle
                                                            .valueColor,
                                                      ),
                                            ),
                                          ),
                                          if (bot.isTest) ...[
                                            const SizedBox(width: 8),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.orange.withValues(
                                                  alpha: 0.3,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                '测试',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: AppFinanceStyle
                                                          .textDefault,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (account != null) ...[
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '月初',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(color: _cardLabelColor),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _fmt(account.initialBalance),
                                        style: topMetricStyle,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '资产余额',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(color: _cardLabelColor),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _fmt(
                                          account.cashBalance ??
                                              account.balanceUsdt,
                                        ),
                                        style: topMetricStyle,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '盈利率',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(color: _cardLabelColor),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        formatUiPercentLabel(
                                          account.profitPercent,
                                        ),
                                        style: topMetricStyle,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 12),
                            if (snapshots.isNotEmpty)
                              SizedBox(
                                height: 128,
                                child: _ProfitLineChart(snapshots: snapshots),
                              )
                            else
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  '暂无收益曲线数据，约 10 分钟更新一次',
                                  style: AppFinanceStyle.labelTextStyle(
                                    context,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _ProfitLineChart extends StatelessWidget {
  const _ProfitLineChart({required this.snapshots});

  final List<BotProfitSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) return const SizedBox.shrink();
    final spots = <FlSpot>[];
    double minY = 0, maxY = 0;
    for (var i = 0; i < snapshots.length; i++) {
      final p = snapshots[i].profitPercent;
      spots.add(FlSpot(i.toDouble(), p));
      if (p < minY) minY = p;
      if (p > maxY) maxY = p;
    }
    if (minY == maxY) {
      minY = minY - 1;
      maxY = maxY + 1;
    }
    final isPositive =
        snapshots.isNotEmpty && (snapshots.last.profitPercent >= 0);
    final lineColor = isPositive
        ? AppFinanceStyle.textProfit
        : AppFinanceStyle.textLoss;
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (snapshots.length - 1).clamp(0, double.infinity).toDouble(),
        minY: minY - 2,
        maxY: maxY + 2,
        gridData: FlGridData(show: false),
        titlesData: FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: lineColor,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color:
                  (isPositive
                          ? AppFinanceStyle.textProfit
                          : AppFinanceStyle.textLoss)
                      .withValues(alpha: 0.25),
            ),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 150),
    );
  }
}
