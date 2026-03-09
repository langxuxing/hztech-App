import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;

import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../widgets/water_background.dart';

// #region agent log
void _agentLog(
  String location,
  String message,
  Map<String, dynamic> data, {
  String? hypothesisId,
}) {
  final payload = <String, dynamic>{
    'sessionId': 'e2e5a8',
    'location': location,
    'message': message,
    'data': data,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    if (hypothesisId != null) 'hypothesisId': hypothesisId,
  };
  http
      .post(
        Uri.parse(
          'http://127.0.0.1:7759/ingest/e6327e07-fe57-429c-be6d-c9b352c12dad',
        ),
        headers: {
          'Content-Type': 'application/json',
          'X-Debug-Session-Id': 'e2e5a8',
        },
        body: jsonEncode(payload),
      )
      .catchError((_, __) => Future.value(http.Response('', 500)));
}
// #endregion

class BotListScreen extends StatefulWidget {
  const BotListScreen({super.key});

  @override
  State<BotListScreen> createState() => _BotListScreenState();
}

class _BotListScreenState extends State<BotListScreen> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _list = [];
  List<AccountProfit> _accounts = [];
  Map<String, List<BotProfitSnapshot>> _profitHistory = {};
  bool _loading = true;
  String? _error;
  String? _loadingBotId;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      // #region agent log
      _agentLog('bot_list_screen.dart:_load', 'entry', {
        'baseUrlLen': baseUrl.length,
        'hasToken': token != null && token.isNotEmpty,
      }, hypothesisId: 'H3');
      // #endregion
      final api = ApiClient(baseUrl, token: token);
      final botsResp = await api.getTradingBots();
      // #region agent log
      final bots = botsResp.botList;
      _agentLog('bot_list_screen.dart:_load', 'after_getTradingBots', {
        'botListLength': bots.length,
        'rawBotsNull': botsResp.bots == null,
        'rawTradingbotsNull': botsResp.tradingbots == null,
      }, hypothesisId: 'H1,H5');
      // #endregion
      if (!mounted) return;
      // 并行拉取账户收益与各机器人收益历史，再一次性 setState，避免先出列表再迟 2 秒出数据
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
        if (hr.snapshots.isNotEmpty)
          history[bots[i].tradingbotId] = hr.snapshots;
      }
      // #region agent log
      _agentLog(
        'bot_list_screen.dart:_load',
        'before_setState_success',
        {'listLength': bots.length, 'accountsLength': accounts.length},
        hypothesisId: 'H2,H4',
      );
      // #endregion
      if (!mounted) return;
      setState(() {
        _list = bots;
        _accounts = accounts;
        _profitHistory = history;
        _loading = false;
      });
    } catch (e) {
      // #region agent log
      _agentLog('bot_list_screen.dart:_load', 'catch', {
        'error': e.toString(),
        'errorType': e.runtimeType.toString(),
      }, hypothesisId: 'H2,H3');
      // #endregion
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  AccountProfit? _accountForBot(UnifiedTradingBot bot, int index) {
    if (_accounts.isEmpty) return null;
    if (index >= 0 && index < _accounts.length) return _accounts[index];
    final ex = bot.exchangeAccount;
    if (ex != null && ex.isNotEmpty) {
      for (final a in _accounts) {
        if (a.exchangeAccount == ex) return a;
      }
    }
    return _accounts.isNotEmpty ? _accounts.first : null;
  }

  void _onTapButton(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    if (running) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认停止'),
          content: const Text('确定要停止该策略吗？此操作将终止当前运行，请确认以防误操作。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () {
                Navigator.pop(ctx);
                _doStop(bot);
              },
              child: const Text('确定停止'),
            ),
          ],
        ),
      );
      return;
    }
    _doStart(bot);
  }

  Future<void> _doStart(UnifiedTradingBot bot) async {
    setState(() => _loadingBotId = bot.tradingbotId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.startBot(bot.tradingbotId);
      if (!mounted) return;
      setState(() => _loadingBotId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(resp.success ? '启动成功' : (resp.message ?? '启动失败')),
        ),
      );
      if (resp.success) _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingBotId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请求失败: $e')));
    }
  }

  Future<void> _doStop(UnifiedTradingBot bot) async {
    setState(() => _loadingBotId = bot.tradingbotId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.stopBot(bot.tradingbotId);
      if (!mounted) return;
      setState(() => _loadingBotId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(resp.success ? '停止成功' : (resp.message ?? '停止失败')),
        ),
      );
      if (resp.success) _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingBotId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请求失败: $e')));
    }
  }

  String _fmt(double v) => v.toStringAsFixed(2);

  static const _barBg = AppFinanceStyle.backgroundDark;
  static const _barTextColor = AppFinanceStyle.valueColor;
  static const _cardLabelColor = AppFinanceStyle.labelColor;
  static const _cardNumberColor = AppFinanceStyle.profitGreenEnd;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '策略机器人',
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
                        Icons.smart_toy_outlined,
                        size: 64,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '暂无策略机器人',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '请检查后端 botconfig/tradingbots.json 或下拉刷新',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
                  itemCount: _list.length,
                  itemBuilder: (context, i) {
                    final bot = _list[i];
                    final account = _accountForBot(bot, i);
                    final snapshots = _profitHistory[bot.tradingbotId] ?? [];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: FinanceCard(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Center(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          bot.tradingbotName ??
                                              bot.tradingbotId,
                                          style:
                                              (Theme.of(
                                                        context,
                                                      ).textTheme.titleLarge ??
                                                      const TextStyle())
                                                  .copyWith(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize:
                                                        (Theme.of(context)
                                                                .textTheme
                                                                .titleLarge
                                                                ?.fontSize ??
                                                            22) +
                                                        4,
                                                    color: AppFinanceStyle
                                                        .valueColor,
                                                  ),
                                          textAlign: TextAlign.center,
                                        ),
                                        if (bot.isTest) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
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
                                                    color: Colors.orange,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                if (bot.canControl)
                                  _buildSingleActionButton(bot),
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
                                      const SizedBox(height: 12),
                                      Text(
                                        _fmt(account.initialBalance),

                                        style:
                                            (Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium ??
                                                    const TextStyle())
                                                .copyWith(
                                                  color: _cardNumberColor,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize:
                                                      (Theme.of(context)
                                                              .textTheme
                                                              .titleLarge
                                                              ?.fontSize ??
                                                          22) +
                                                      4,
                                                ),
                                      ),
                                    ],
                                  ),
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '当前',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(color: _cardLabelColor),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        _fmt(account.currentBalance),
                                        style:
                                            (Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium ??
                                                    const TextStyle())
                                                .copyWith(
                                                  color: _cardNumberColor,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize:
                                                      (Theme.of(context)
                                                              .textTheme
                                                              .titleLarge
                                                              ?.fontSize ??
                                                          22) +
                                                      4,
                                                ),
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
                                      const SizedBox(height: 12),
                                      Text(
                                        '${account.profitPercent.toStringAsFixed(1)}%',
                                        style:
                                            (Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium ??
                                                    const TextStyle())
                                                .copyWith(
                                                  color: _cardNumberColor,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize:
                                                      (Theme.of(context)
                                                              .textTheme
                                                              .titleLarge
                                                              ?.fontSize ??
                                                          22) +
                                                      4,
                                                ),
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
                                  vertical: 16,
                                ),
                                child: Text(
                                  '暂无收益数据，约 10 分钟更新一次',
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

  Widget _buildSingleActionButton(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    final isLoading = _loadingBotId == bot.tradingbotId;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isLoading ? null : () => _onTapButton(bot),
        borderRadius: BorderRadius.circular(33),
        child: Container(
          width: 66,
          height: 66,
          decoration: BoxDecoration(
            color: isLoading
                ? Colors.grey.withValues(alpha: 0.2)
                : (running
                      ? Colors.red.withValues(alpha: 0.2)
                      : Colors.green.withValues(alpha: 0.2)),
            shape: BoxShape.circle,
          ),
          child: isLoading
              ? const Padding(
                  padding: EdgeInsets.all(15),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  color: running ? Colors.red : Colors.green,
                  size: 42,
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
    final lineColor = isPositive ? AppFinanceStyle.profitGreenEnd : Colors.red;
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
              color: (isPositive ? AppFinanceStyle.profitGreenEnd : Colors.red)
                  .withValues(alpha: 0.25),
            ),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 150),
    );
  }
}
