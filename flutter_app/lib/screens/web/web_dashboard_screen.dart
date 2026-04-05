import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/profit_percent_line_chart.dart';
import '../../widgets/water_background.dart';
import 'web_account_profit_screen.dart';

/// Web 全局数据看板：汇总权益与盈亏，点击进入账户详情。
/// 脚本启停见 [WebTradingBotControlScreen]（导航「策略启动」）。
class WebDashboardScreen extends StatefulWidget {
  const WebDashboardScreen({super.key, this.sharedBots = const []});
  final List<UnifiedTradingBot> sharedBots;
  @override
  State<WebDashboardScreen> createState() => _WebDashboardScreenState();
}

class _WebDashboardScreenState extends State<WebDashboardScreen> {
  final _prefs = SecurePrefs();

  //账户列表
  List<AccountProfit> _accounts = [];
  // 账户收益历史
  Map<String, List<BotProfitSnapshot>> _profitHistory = {};
  // 是否加载中
  bool _loading = true;
  // 错误信息
  String? _error;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final profitResp = await api.getAccountProfit();
      final accounts = profitResp.accounts ?? [];
      final Map<String, List<BotProfitSnapshot>> history = {};
      try {
        final ids = accounts
            .map((a) => a.botId)
            .where((id) => id.isNotEmpty)
            .toList();
        if (ids.isNotEmpty) {
          final results = await Future.wait(
            ids.map((id) => api.getBotProfitHistory(id)),
          );
          for (var i = 0; i < ids.length && i < results.length; i++) {
            final snaps = results[i].snapshots;
            if (snaps.isNotEmpty) {
              history[ids[i]] = snaps;
            }
          }
        }
      } catch (_) {
        // 卡片仍显示，曲线失败时为空
      }
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _profitHistory = history;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  UnifiedTradingBot? _botFor(AccountProfit a) {
    for (final b in widget.sharedBots) {
      if (b.tradingbotId == a.botId) return b;
    }
    return null;
  }

  void _openAccount(AccountProfit a) {
    final id = a.botId.isNotEmpty ? a.botId : null;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => WebAccountProfitScreen(
          sharedBots: widget.sharedBots,
          initialBotId: id,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading && _accounts.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _accounts.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(height: MediaQuery.sizeOf(context).height * 0.25),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '全局概览',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    color: AppFinanceStyle.valueColor,
                                    // fontWeight（字体粗细）用于设置文本的字重。FontWeight.w900 表示极粗（Black）。
                                    fontWeight: FontWeight.w900,
                                  ),
                            ),
                            const SizedBox(height: 16),

                            if (_accounts.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              _SummaryStrip(accounts: _accounts),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (_accounts.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: Text(
                              '暂无账户数据',
                              style: AppFinanceStyle.labelTextStyle(context),
                            ),
                          ),
                        ),
                      )
                    else
                      Builder(
                        builder: (context) {
                          final w = MediaQuery.sizeOf(context).width;
                          var cross = 1;
                          if (w >= 1200) {
                            cross = 4;
                          } else if (w >= 800) {
                            cross = 3;
                          }
                          return SliverPadding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                            sliver: SliverGrid(
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: cross,
                                    mainAxisSpacing: 16,
                                    crossAxisSpacing: 16,
                                    childAspectRatio: cross >= 3 ? 1.35 : 1.2,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final a = _accounts[index];
                                final bot = _botFor(a);
                                return _OverviewGlassCard(
                                  account: a,
                                  bot: bot,
                                  snapshots:
                                      _profitHistory[a.botId] ?? const [],
                                  onOpen: () => _openAccount(a),
                                );
                              }, childCount: _accounts.length),
                            ),
                          );
                        },
                      ),
                    const SliverPadding(padding: EdgeInsets.only(bottom: 48)),
                  ],
                ),
        ),
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.accounts});

  final List<AccountProfit> accounts;

  @override
  Widget build(BuildContext context) {
    var eq = 0.0;
    var profit = 0.0;
    var initial = 0.0;
    for (final a in accounts) {
      eq += a.equityUsdt;
      profit += a.profitAmount;
      initial += a.initialBalance;
    }
    final pct = initial > 0 ? (profit / initial) * 100 : 0.0;
    TextStyle v(double fs) =>
        AppFinanceStyle.valueTextStyle(context, fontSize: fs);
    return FinanceCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 520;
          final children = [
            _SummaryCell(
              label: '账户数',
              value: '${accounts.length}',
              valueStyle: v(22),
              narrow: narrow,
            ),
            _SummaryCell(
              label: '总权益',
              value: eq.toStringAsFixed(0),
              valueStyle: v(22),
              narrow: narrow,
            ),
            _SummaryCell(
              label: '总盈亏',
              value: profit.toStringAsFixed(0),
              valueStyle: v(22).copyWith(
                color: profit >= 0
                    ? AppFinanceStyle.profitGreenEnd
                    : Colors.redAccent,
              ),
              narrow: narrow,
            ),
            _SummaryCell(
              label: '收益率',
              value: '${pct.toStringAsFixed(0)}%',
              valueStyle: v(22),
              narrow: narrow,
            ),
          ];
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  children[i],
                ],
              ],
            );
          }
          return Row(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                Expanded(child: children[i]),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({
    required this.label,
    required this.value,
    required this.valueStyle,
    required this.narrow,
  });

  final String label;
  final String value;
  final TextStyle valueStyle;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: narrow
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Text(label, style: AppFinanceStyle.labelTextStyle(context)),
        const SizedBox(height: 4),
        Text(
          value,
          style: valueStyle,
          textAlign: narrow ? TextAlign.start : TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _OverviewGlassCard extends StatelessWidget {
  const _OverviewGlassCard({
    required this.account,
    required this.bot,
    required this.snapshots,
    required this.onOpen,
  });

  final AccountProfit account;
  final UnifiedTradingBot? bot;
  final List<BotProfitSnapshot> snapshots;
  final VoidCallback onOpen;

  static const _labelColor = AppFinanceStyle.labelColor;
  static const _numberColor = AppFinanceStyle.profitGreenEnd;

  @override
  Widget build(BuildContext context) {
    final title =
        bot?.tradingbotName ??
        (account.exchangeAccount.isNotEmpty
            ? account.exchangeAccount
            : account.botId);
    final titleStyle =
        (Theme.of(context).textTheme.titleMedium ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w800,
          fontSize: (Theme.of(context).textTheme.titleMedium?.fontSize ?? 20),
          color: AppFinanceStyle.valueColor,
        );
    return FinanceCard(
      padding: const EdgeInsets.all(16),
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: titleStyle,

                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (bot?.isTest == true) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '测试',
                          style: Theme.of(context).textTheme.labelSmall
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
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _OverviewStatCol(
                label: '月初',
                value: account.initialBalance.toStringAsFixed(0),
              ),
              _OverviewStatCol(
                label: '现金余额',
                value: account.balanceUsdt.toStringAsFixed(0),
              ),
              _OverviewStatCol(
                label: '盈利率',
                value: '${account.profitPercent.toStringAsFixed(0)}%',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: snapshots.isNotEmpty
                ? ProfitPercentLineChart(snapshots: snapshots)
                : Center(
                    child: Text(
                      '暂无收益',
                      style: AppFinanceStyle.labelTextStyle(context),
                      textAlign: TextAlign.center,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _OverviewStatCol extends StatelessWidget {
  const _OverviewStatCol({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final numStyle =
        (Theme.of(context).textTheme.titleSmall ?? const TextStyle()).copyWith(
          color: _OverviewGlassCard._numberColor,
          fontWeight: FontWeight.bold,
          fontSize: (Theme.of(context).textTheme.titleLarge?.fontSize ?? 20),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: _OverviewGlassCard._labelColor,
          ),
        ),
        const SizedBox(height: 3),
        Text(value, style: numStyle),
      ],
    );
  }
}
