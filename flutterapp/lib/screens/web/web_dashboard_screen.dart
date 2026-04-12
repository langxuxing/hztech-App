import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../utils/number_display_format.dart';
import '../../widgets/equity_cash_percent_line_chart.dart';
import '../../widgets/month_end_profit_panel.dart' show focusedMonthFromProfitSnapshots;
import '../../widgets/water_background.dart';
import 'web_account_profile_screen.dart';

/// 总览页金额口径：默认权益；可切换为 USDT 现金余额及相关盈亏。
enum _DashboardBasis { equity, cash }

/// Web「账户总览」：与侧栏 [WebMainShell] 文案一致，汇总权益与盈亏；点击卡片由 [onOpenAccountProfit]
/// 切到「账户收益」Tab（与侧栏点入同一布局，含左侧菜单）。无回调时仍走独立 push。
/// 脚本启停见 [WebTradingBotControlScreen]（侧栏「策略启停」）。
class WebDashboardScreen extends StatefulWidget {
  const WebDashboardScreen({
    super.key,
    this.sharedBots = const [],
    this.onOpenAccountProfit,
  });

  final List<UnifiedTradingBot> sharedBots;

  /// 嵌入 [WebMainShell] 时由壳层切换到「账户收益」侧栏 Tab（保留左侧菜单），并可选带上默认 bot。
  final void Function(String? botId)? onOpenAccountProfit;
  @override
  State<WebDashboardScreen> createState() => _WebDashboardScreenState();
}

class _WebDashboardScreenState extends State<WebDashboardScreen> {
  final _prefs = SecurePrefs();

  /// 仪表盘卡片小图仅需近期快照：减小 limit 与窗口，降低 JSON 体积与后端排序压力（不经 OKX）。
  static const int _kDashboardProfitHistoryLimit = 2500;
  static const int _kDashboardProfitHistoryDays = 50;

  /// 默认权益口径；可切换现金余额口径。
  _DashboardBasis _basis = _DashboardBasis.equity;

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
          final sinceUtc = DateTime.now()
              .toUtc()
              .subtract(const Duration(days: _kDashboardProfitHistoryDays));
          final sinceIso =
              '${sinceUtc.year.toString().padLeft(4, '0')}-'
              '${sinceUtc.month.toString().padLeft(2, '0')}-'
              '${sinceUtc.day.toString().padLeft(2, '0')}T00:00:00.000Z';
          final results = await Future.wait(
            ids.map(
              (id) => api.getBotProfitHistory(
                id,
                limit: _kDashboardProfitHistoryLimit,
                since: sinceIso,
              ),
            ),
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
    final open = widget.onOpenAccountProfit;
    if (open != null) {
      open(id);
      return;
    }
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
                            const SizedBox(height: AppFinanceStyle.webSummaryTitleSpacing),
                            if (_accounts.isNotEmpty) ...[
                              Row(
                                children: [
                                  const Spacer(),
                                  SegmentedButton<_DashboardBasis>(
                                    style: ButtonStyle(
                                      visualDensity: VisualDensity.compact,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    showSelectedIcon: false,
                                    segments: const [
                                      ButtonSegment(
                                        value: _DashboardBasis.equity,
                                        label: Text('权益'),
                                        tooltip: '权益金额口径',
                                      ),
                                      ButtonSegment(
                                        value: _DashboardBasis.cash,
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
                              _SummaryStrip(
                                accounts: _accounts,
                                basis: _basis,
                              ),
                            ],
                            if (_accounts.isNotEmpty)
                              const SizedBox(height: 12),
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
                                  basis: _basis,
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
  const _SummaryStrip({
    required this.accounts,
    required this.basis,
  });

  final List<AccountProfit> accounts;
  final _DashboardBasis basis;

  @override
  Widget build(BuildContext context) {
    var eq = 0.0;
    var profit = 0.0;
    var initial = 0.0;
    for (final a in accounts) {
      initial += a.initialBalance;
      if (basis == _DashboardBasis.equity) {
        eq += a.equityUsdt;
        profit += a.profitAmount;
      } else {
        eq += a.cashBalance ?? a.balanceUsdt;
        profit += a.cashProfitAmount;
      }
    }
    final pct = initial > 0 ? (profit / initial) * 100 : 0.0;
    TextStyle v() => AppFinanceStyle.valueTextStyle(
      context,
      fontSize: AppFinanceStyle.webSummaryValueFontSize,
    );
    return FinanceCard(
      padding: AppFinanceStyle.webSummaryStripPadding,
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 520;
          final children = [
            _SummaryCell(
              label: '账户数',
              value: '${accounts.length}',
              valueStyle: v(),
              trailingLabel: !narrow,
            ),
            _SummaryCell(
              label: basis == _DashboardBasis.equity ? '总权益' : '总现金',
              value: formatUiInteger(eq),
              valueStyle: v(),
              trailingLabel: !narrow,
            ),
            _SummaryCell(
              label: basis == _DashboardBasis.equity ? '总盈亏' : '总现金收益',
              value: formatUiInteger(profit),
              valueStyle: v().copyWith(
                color: profit >= 0
                    ? AppFinanceStyle.textProfit
                    : AppFinanceStyle.textLoss,
              ),
              trailingLabel: !narrow,
            ),
            _SummaryCell(
              label: basis == _DashboardBasis.equity ? '平均收益率' : '平均现金收益率',
              value: formatUiPercentLabel(pct),
              valueStyle: v(),
              trailingLabel: !narrow,
            ),
          ];
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    const SizedBox(height: AppFinanceStyle.webSummaryNarrowGap),
                  children[i],
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  const SizedBox(width: AppFinanceStyle.webSummaryWideGap),
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

    /// 宽屏：标签与数值同一基线横排；列在 `Expanded` 内水平居中。窄屏：整体左对齐。
    required this.trailingLabel,
  });

  final String label;
  final String value;
  final TextStyle valueStyle;
  final bool trailingLabel;

  @override
  Widget build(BuildContext context) {
    final baseLabel = AppFinanceStyle.labelTextStyle(context);
    final labelStyle = baseLabel.copyWith(
      fontSize: (baseLabel.fontSize ?? 14) - 2,
    );
    final ta = trailingLabel ? TextAlign.end : TextAlign.start;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label, style: labelStyle, textAlign: ta),
        const SizedBox(width: 6),
        Text(
          value,
          style: valueStyle,
          textAlign: ta,
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
    required this.basis,
    required this.onOpen,
  });

  final AccountProfit account;
  final UnifiedTradingBot? bot;
  final List<BotProfitSnapshot> snapshots;
  final _DashboardBasis basis;
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
                                color: AppFinanceStyle.textDefault,
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
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _OverviewStatCol(
                label: '月初',
                value: formatUiInteger(account.initialBalance),
              ),
              _OverviewStatCol(
                label: basis == _DashboardBasis.equity ? '当前权益' : '当前现金',
                value: formatUiInteger(
                  basis == _DashboardBasis.equity
                      ? account.equityUsdt
                      : (account.cashBalance ?? account.balanceUsdt),
                ),
              ),
              _OverviewStatCol(
                label: basis == _DashboardBasis.equity ? '收益率' : '现金收益率',
                value: formatUiPercentLabel(
                  basis == _DashboardBasis.equity
                      ? account.profitPercent
                      : account.cashProfitPercent,
                ),
              ),
            ],
          ),
          if (snapshots.isNotEmpty) ...[
            const SizedBox(height: 8),
            Expanded(
              child: IgnorePointer(
                child: SnapshotPercentLineChart(
                  snapshots: snapshots,
                  series: basis == _DashboardBasis.equity
                      ? SnapshotReturnSeries.equity
                      : SnapshotReturnSeries.cash,
                  compact: true,
                  focusedMonth: focusedMonthFromProfitSnapshots(snapshots),
                  monthOpenLevelHint: basis == _DashboardBasis.equity
                      ? (account.monthInitialEquity ?? account.initialBalance)
                      : (account.monthInitialBalance ??
                          account.cashBalance ??
                          account.initialBalance),
                ),
              ),
            ),
          ],
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
    final baseNumSize = Theme.of(context).textTheme.titleLarge?.fontSize ?? 20;
    final numStyle =
        (Theme.of(context).textTheme.titleSmall ?? const TextStyle()).copyWith(
          color: _OverviewGlassCard._numberColor,
          fontWeight: FontWeight.w600,
          fontSize: baseNumSize - 2,
        );
    final baseLabelSize = Theme.of(context).textTheme.bodySmall?.fontSize ?? 12;
    final labelStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: _OverviewGlassCard._labelColor,
      fontSize: baseLabelSize - 2,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label, style: labelStyle),
        const SizedBox(width: 6),
        Text(value, style: numStyle),
      ],
    );
  }
}
