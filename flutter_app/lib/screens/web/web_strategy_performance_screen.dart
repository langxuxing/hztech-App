import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/profit_percent_line_chart.dart';
import '../../widgets/water_background.dart';

/// Web：按账户查看收益率曲线、赛季网格与策略日线能效（OKX TR 与现金日变动比值）。
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
  StrategyDailyEfficiencyResponse? _efficiency;
  bool _loading = true;
  String? _metricsError;
  String? _efficiencyLoadError;

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

  Future<void> _loadData() async {
    final botId = _selectedId;
    if (botId == null || botId.isEmpty) return;
    setState(() {
      _loading = true;
      _metricsError = null;
      _efficiencyLoadError = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);

      String? mErr;
      String? eErr;
      BotProfitHistoryResponse? hResp;
      TradingbotSeasonsResponse? sResp;
      StrategyDailyEfficiencyResponse? effResp;

      await Future.wait([
        (() async {
          try {
            final r = await Future.wait([
              api.getBotProfitHistory(botId, limit: 500),
              api.getTradingbotSeasons(botId, limit: 50),
            ]);
            hResp = r[0] as BotProfitHistoryResponse;
            sResp = r[1] as TradingbotSeasonsResponse;
          } catch (e) {
            mErr = e.toString();
          }
        })(),
        (() async {
          try {
            effResp = await api.getStrategyDailyEfficiency(botId);
          } catch (e) {
            eErr = e.toString();
          }
        })(),
      ]);

      if (!mounted) return;
      setState(() {
        if (hResp != null && sResp != null) {
          _snapshots = hResp!.snapshots;
          _seasons = sResp!.seasons;
        } else {
          _snapshots = [];
          _seasons = [];
        }
        _efficiency = effResp;
        _metricsError = mErr;
        _efficiencyLoadError = eErr;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _metricsError = e.toString();
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
    await _loadData();
  }

  String _fmtPct(double v) => '${v.toStringAsFixed(2)}%';

  String _fmt(double v) => v.toStringAsFixed(2);

  String _fmtOpt(double? v, {int digits = 2}) {
    if (v == null || !v.isFinite) return '—';
    return v.toStringAsFixed(digits);
  }

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

  Widget _buildEfficiencySection(BuildContext context) {
    if (_efficiencyLoadError != null) {
      return FinanceCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '策略能效评估',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppFinanceStyle.labelColor,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _efficiencyLoadError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
      );
    }
    final eff = _efficiency;
    if (eff == null) {
      return const SizedBox.shrink();
    }
    if (!eff.success) {
      return FinanceCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '策略能效评估',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppFinanceStyle.labelColor,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              eff.message ?? '市场数据不可用（请检查网络或交易对代码）',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
      );
    }
    final rows = eff.rows.take(90).toList();
    final cashNote = eff.cashBasis == 'account_snapshots_cash'
        ? '现金变动来自 account_snapshots（availEq），按 UTC 自然日汇总。'
        : '非 Account_List 账户无现金快照列；仍显示 OKX 日线 TR。';
    return FinanceCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '策略能效评估',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppFinanceStyle.labelColor,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            '${eff.instId} 日线 True Range（OKX 公开 K 线）；比值 = 现金日变动% ÷ TR 占收盘价%。$cashNote',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 40,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 48,
              columns: const [
                DataColumn(label: Text('日期(UTC)')),
                DataColumn(label: Text('TR'), numeric: true),
                DataColumn(label: Text('TR%'), numeric: true),
                DataColumn(label: Text('现金Δ USDT'), numeric: true),
                DataColumn(label: Text('现金Δ%'), numeric: true),
                DataColumn(label: Text('比值'), numeric: true),
              ],
              rows: [
                for (final e in rows)
                  DataRow(
                    cells: [
                      DataCell(Text(e.day)),
                      DataCell(Text(_fmtOpt(e.tr, digits: 6))),
                      DataCell(Text(_fmtOpt(e.trPct))),
                      DataCell(
                        Text(
                          _fmtOpt(e.cashDeltaUsdt),
                          style: TextStyle(
                            color: (e.cashDeltaUsdt ?? 0) >= 0
                                ? AppFinanceStyle.profitGreenEnd
                                : Colors.red,
                          ),
                        ),
                      ),
                      DataCell(Text(_fmtOpt(e.cashDeltaPct))),
                      DataCell(Text(_fmtOpt(e.efficiencyRatio))),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: RefreshIndicator(
          onRefresh: () async {
            await _loadBots();
            await _loadData();
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
                              key: ValueKey(_selectedId),
                              initialValue:
                                  _selectedId ?? _bots.first.tradingbotId,
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
                                await _loadData();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_metricsError != null)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      '收益/赛季：${_metricsError!}',
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
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
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
                            if (_metricsError != null)
                              FinanceCard(
                                padding: const EdgeInsets.all(24),
                                child: Center(
                                  child: Text(
                                    '赛季数据加载失败',
                                    style: AppFinanceStyle.labelTextStyle(context),
                                  ),
                                ),
                              )
                            else if (_seasons.isEmpty)
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
                                  for (final e in _seasons.take(24).toList().asMap().entries)
                                    seasonCard(e.value, e.key + 1),
                                ],
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 48),
                  sliver: SliverToBoxAdapter(child: _buildEfficiencySection(context)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
