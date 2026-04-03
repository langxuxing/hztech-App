import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/profit_percent_line_chart.dart';
import '../../widgets/water_background.dart';

/// Web：按账户查看收益率曲线；赛季为**每张赛季一张卡片**的网格布局。
/// 与 APK [AccountProfitScreen] 中单卡内「赛季盈利」列表式展示区分。
class WebStrategyPerformanceScreen extends StatefulWidget {
  const WebStrategyPerformanceScreen({super.key, this.sharedBots = const []});

  final List<UnifiedTradingBot> sharedBots;

  @override
  State<WebStrategyPerformanceScreen> createState() =>
      _WebStrategyPerformanceScreenState();
}

class _WebStrategyPerformanceScreenState
    extends State<WebStrategyPerformanceScreen> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _bots = [];
  String? _selectedId;
  List<BotProfitSnapshot> _snapshots = [];
  List<BotSeason> _seasons = [];
  bool _loading = true;
  String? _error;

  Future<void> _loadBots() async {
    if (widget.sharedBots.isNotEmpty) {
      setState(() {
        _bots = List.from(widget.sharedBots);
        _selectedId ??= _bots.first.tradingbotId;
      });
      return;
    }
    final baseUrl = await _prefs.backendBaseUrl;
    final token = await _prefs.authToken;
    final api = ApiClient(baseUrl, token: token);
    final resp = await api.getTradingBots();
    if (!mounted) return;
    setState(() {
      _bots = resp.botList;
      if (_selectedId == null && _bots.isNotEmpty) {
        _selectedId = _bots.first.tradingbotId;
      }
    });
  }

  Future<void> _loadMetrics() async {
    final botId = _selectedId;
    if (botId == null || botId.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final r = await Future.wait([
        api.getBotProfitHistory(botId, limit: 500),
        api.getTradingbotSeasons(botId, limit: 50),
      ]);
      if (!mounted) return;
      final h = r[0] as BotProfitHistoryResponse;
      final s = r[1] as TradingbotSeasonsResponse;
      setState(() {
        _snapshots = h.snapshots;
        _seasons = s.seasons;
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadBots();
    if (!mounted) return;
    if (_bots.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    await _loadMetrics();
  }

  String _fmtPct(double v) => '${v.toStringAsFixed(2)}%';

  String _fmt(double v) => v.toStringAsFixed(2);

  /// 与移动端赛季时间展示一致：月-日 时:分
  String _formatSeasonTime(String? value) {
    if (value == null || value.length < 16) return '-';
    try {
      final s = value
          .substring(0, value.length >= 19 ? 19 : value.length)
          .replaceAll('T', ' ');
      if (s.length < 16) return '-';
      final parts = s.split(' ');
      final dateParts = parts[0].split('-');
      final timePart = parts.length > 1 ? parts[1].substring(0, 5) : '00:00';
      if (dateParts.length < 3) return '-';
      return '${dateParts[1]}-${dateParts[2]} $timePart';
    } catch (_) {
      return '-';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: RefreshIndicator(
          onRefresh: () async {
            await _loadBots();
            await _loadMetrics();
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                sliver: SliverToBoxAdapter(
                  child: FinanceCard(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '选择账户',
                            style: AppFinanceStyle.labelTextStyle(context),
                          ),
                        ),
                        if (_bots.isNotEmpty)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 360),
                            child: DropdownButtonFormField<String>(
                              value: _selectedId ?? _bots.first.tradingbotId,
                              isExpanded: true,
                              dropdownColor: AppFinanceStyle.cardBackground,
                              style: const TextStyle(color: AppFinanceStyle.valueColor),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: 0.06),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              items: _bots
                                  .map(
                                    (b) => DropdownMenuItem<String>(
                                      value: b.tradingbotId,
                                      child: Text(
                                        b.tradingbotName ?? b.tradingbotId,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) async {
                                if (v == null) return;
                                setState(() => _selectedId = v);
                                await _loadMetrics();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_error != null)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ),
              if (_loading)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_bots.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Text(
                      '暂无交易账户',
                      style: AppFinanceStyle.labelTextStyle(context),
                    ),
                  ),
                )
              else ...[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  sliver: SliverToBoxAdapter(
                    child: FinanceCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '收益率曲线',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: AppFinanceStyle.labelColor,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 220,
                            child: ProfitPercentLineChart(snapshots: _snapshots),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 48),
                  sliver: SliverToBoxAdapter(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final maxW = constraints.maxWidth;
                        const gap = 16.0;
                        final cols = maxW >= 960
                            ? 3
                            : maxW >= 560
                                ? 2
                                : 1;
                        final cardW = cols > 1
                            ? (maxW - gap * (cols - 1)) / cols
                            : maxW;

                        Widget seasonCard(BotSeason s, int index) {
                          final profitColor = (s.profitAmount ?? 0) >= 0
                              ? AppFinanceStyle.profitGreenEnd
                              : Colors.red;
                          return SizedBox(
                            width: cardW,
                            child: FinanceCard(
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '赛季 $index',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall
                                              ?.copyWith(
                                                color: AppFinanceStyle.valueColor,
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: profitColor.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: profitColor.withValues(alpha: 0.35),
                                          ),
                                        ),
                                        child: Text(
                                          _fmtPct(s.profitPercent ?? 0),
                                          style: TextStyle(
                                            color: profitColor,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    '${_formatSeasonTime(s.startedAt)}  →  ${_formatSeasonTime(s.stoppedAt)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: AppFinanceStyle.labelColor,
                                        ),
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    '收益',
                                    style: AppFinanceStyle.labelTextStyle(context)
                                        .copyWith(fontSize: 12),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _fmt(s.profitAmount ?? 0),
                                    style: TextStyle(
                                      color: profitColor,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 22,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                  if (s.initialBalance > 0 ||
                                      (s.finalBalance != null && s.finalBalance! > 0)) ...[
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '期初 ${_fmt(s.initialBalance)}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall
                                                ?.copyWith(
                                                  color: AppFinanceStyle.labelColor,
                                                ),
                                          ),
                                        ),
                                        if (s.finalBalance != null)
                                          Text(
                                            '期末 ${_fmt(s.finalBalance!)}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall
                                                ?.copyWith(
                                                  color: AppFinanceStyle.labelColor,
                                                ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '赛季',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: AppFinanceStyle.labelColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            if (_seasons.isEmpty)
                              FinanceCard(
                                padding: const EdgeInsets.all(24),
                                child: Center(
                                  child: Text(
                                    '暂无赛季数据',
                                    style: AppFinanceStyle.labelTextStyle(context),
                                  ),
                                ),
                              )
                            else
                              Wrap(
                                spacing: gap,
                                runSpacing: gap,
                                children: [
                                  for (var i = 0; i < _seasons.take(24).length; i++)
                                    seasonCard(_seasons[i], i + 1),
                                ],
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

