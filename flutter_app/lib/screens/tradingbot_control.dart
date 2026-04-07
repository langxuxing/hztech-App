import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import '../widgets/water_background.dart';

/// 交易机器人：列表来自 main.py /api/tradingbots（Account_List.json），
/// 启停走 script_file（如 tradingbot_ctrl/moneyflow_alangsandbox.sh start|stop）。
class TradingBotControl extends StatefulWidget {
  const TradingBotControl({super.key, this.embedInShell = false});

  /// 嵌入 Web 主导航壳时不显示本页 [AppBar]，避免与壳重复。
  final bool embedInShell;

  @override
  State<TradingBotControl> createState() => _TradingBotControlState();
}

class _TradingBotControlState extends State<TradingBotControl> {
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
      } catch (_) {
        // 列表已显示，收益/曲线失败时保留空数据
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
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

  /// 与 Web 端一致：停止前二次确认。
  void _onTapStop(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    if (!running) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认停止'),
        content: const Text('确定要停止该账户策略吗？此操作将终止当前运行，请确认以防误操作。'),
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
  }

  void _onTapStart(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    if (running) return;
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
                '策略启停',
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
                          itemCount: _list.length,
                          itemBuilder: (context, i) {
                            final bot = _list[i];
                            final account = _accountForBot(bot, i);
                            final snapshots = _profitHistory[bot.tradingbotId] ?? [];
                            final running =
                                bot.status == 'running' || bot.isRunning == true;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 24),
                              child: FinanceCard(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Flexible(
                                                    child: Text(
                                                      bot.tradingbotName ?? bot.tradingbotId,
                                                      style: (Theme.of(context)
                                                                  .textTheme
                                                                  .titleLarge ??
                                                              const TextStyle())
                                                          .copyWith(
                                                            fontWeight: FontWeight.w800,
                                                            fontSize: (Theme.of(context)
                                                                        .textTheme
                                                                        .titleLarge
                                                                        ?.fontSize ??
                                                                    22) +
                                                                2,
                                                            color: AppFinanceStyle.valueColor,
                                                          ),
                                                    ),
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
                                                        borderRadius: BorderRadius.circular(4),
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
                                              const SizedBox(height: 6),
                                              Text(
                                                running ? '运行中' : '已停止',
                                                style: AppFinanceStyle.labelTextStyle(
                                                  context,
                                                ).copyWith(
                                                  color: running
                                                      ? Colors.greenAccent
                                                      : AppFinanceStyle.labelColor,
                                                ),
                                              ),
                                              if (!bot.canControl) ...[
                                                const SizedBox(height: 6),
                                                Text(
                                                  '未配置 accounts 目录下的启停脚本（script_file）',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .outline,
                                                      ),
                                                ),
                                              ],
                                              if (bot.symbol != null &&
                                                  bot.symbol!.isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  '交易对 ${bot.symbol}',
                                                  style: AppFinanceStyle.labelTextStyle(
                                                    context,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        if (bot.canControl)
                                          _buildStrategyStartStopRow(bot),
                                      ],
                                    ),
                                    if (account != null) ...[
                                      const SizedBox(height: 12),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceAround,
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
                                                style: (Theme.of(context)
                                                            .textTheme.titleMedium ??
                                                        const TextStyle())
                                                    .copyWith(
                                                      color: _cardNumberColor,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: (Theme.of(context)
                                                                  .textTheme
                                                                  .titleLarge
                                                                  ?.fontSize ??
                                                              22) +
                                                          2,
                                                    ),
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
                                                _fmt(account.cashBalance ??
                                                    account.balanceUsdt),
                                                style: (Theme.of(context)
                                                            .textTheme.titleMedium ??
                                                        const TextStyle())
                                                    .copyWith(
                                                      color: _cardNumberColor,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: (Theme.of(context)
                                                                  .textTheme
                                                                  .titleLarge
                                                                  ?.fontSize ??
                                                              22) +
                                                          2,
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
                                              const SizedBox(height: 8),
                                              Text(
                                                formatUiPercentLabel(
                                                  account.profitPercent,
                                                ),
                                                style: (Theme.of(context)
                                                            .textTheme.titleMedium ??
                                                        const TextStyle())
                                                    .copyWith(
                                                      color: _cardNumberColor,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: (Theme.of(context)
                                                                  .textTheme
                                                                  .titleLarge
                                                                  ?.fontSize ??
                                                              22) +
                                                          2,
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
                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                        child: Text(
                                          '暂无收益曲线数据，约 10 分钟更新一次',
                                          style: AppFinanceStyle.labelTextStyle(context),
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

  /// 与 [WebTradingBotControlScreen] 机器人区一致：独立「启动」「停止」两键；进行中两键均显示加载且不可点。
  Widget _buildStrategyStartStopRow(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    final busy = _loadingBotId == bot.tradingbotId;
    const size = 48.0;
    const iconSize = 26.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _strategyCircleAction(
          size: size,
          iconSize: iconSize,
          accent: Colors.green,
          icon: Icons.play_circle_outline,
          busy: busy,
          enabled: !busy && !running,
          onTap: () => _onTapStart(bot),
        ),
        const SizedBox(width: 12),
        _strategyCircleAction(
          size: size,
          iconSize: iconSize,
          accent: Colors.red,
          icon: Icons.stop_circle_outlined,
          busy: busy,
          enabled: !busy && running,
          onTap: () => _onTapStop(bot),
        ),
      ],
    );
  }

  Widget _strategyCircleAction({
    required double size,
    required double iconSize,
    required Color accent,
    required IconData icon,
    required bool busy,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final canTap = enabled && !busy;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canTap ? onTap : null,
        borderRadius: BorderRadius.circular(size),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: accent.withValues(alpha: canTap ? 0.55 : 0.2),
              width: 1.5,
            ),
            color: accent.withValues(alpha: canTap ? 0.12 : 0.04),
          ),
          child: busy
              ? SizedBox(
                  width: iconSize,
                  height: iconSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: accent.withValues(alpha: 0.85),
                  ),
                )
              : Icon(
                  icon,
                  size: iconSize,
                  color: canTap ? accent : accent.withValues(alpha: 0.35),
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
