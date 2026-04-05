import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/strategy_efficiency_lightweight_chart.dart';
import '../../widgets/water_background.dart';

/// Web：策略效能——每日波动率、现金收益率%（较 UTC 月初）、策略能效，全账户同页对比。
class WebStrategyPerformanceScreen extends StatefulWidget {
  const WebStrategyPerformanceScreen({super.key, this.sharedBots = const []});

  final List<UnifiedTradingBot> sharedBots;

  @override
  State<WebStrategyPerformanceScreen> createState() =>
      _WebStrategyPerformanceScreenState();
}

/// 效能三等：相对排序，一等绿、二等黄、三等灰。
enum _EfficiencyTier {
  first,
  second,
  third,
}

class _BotEfficiencyBundle {
  _BotEfficiencyBundle({
    required this.bot,
    this.response,
    this.fetchError,
  });

  final UnifiedTradingBot bot;
  final StrategyDailyEfficiencyResponse? response;
  final String? fetchError;
  _EfficiencyTier tier = _EfficiencyTier.third;
  double scoreForChart = 0;

  bool get fetchOk => fetchError == null;
  bool get hasEfficiencyData =>
      response != null &&
      response!.success &&
      response!.rows.isNotEmpty;

  static double? _averageRatio(StrategyDailyEfficiencyResponse eff) {
    final ratios = eff.rows
        .map((e) => e.efficiencyRatio)
        .whereType<double>()
        .where((r) => r.isFinite)
        .toList();
    if (ratios.isEmpty) return null;
    var s = 0.0;
    for (final r in ratios) {
      s += r;
    }
    return s / ratios.length;
  }

  static _BotEfficiencyBundle fromLoad(
    UnifiedTradingBot bot,
    StrategyDailyEfficiencyResponse? response,
    String? fetchError,
  ) {
    final b = _BotEfficiencyBundle(
      bot: bot,
      response: response,
      fetchError: fetchError,
    );
    if (response != null &&
        response.success &&
        _averageRatio(response) != null) {
      b.scoreForChart = _averageRatio(response)!;
    }
    return b;
  }
}

class _WebStrategyPerformanceScreenState
    extends State<WebStrategyPerformanceScreen> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _bots = [];
  List<_BotEfficiencyBundle> _bundles = [];
  bool _loading = true;
  String? _loadError;

  static const Color _tierGreen = Color(0xFF7EC850);
  static const Color _tierYellow = Color(0xFFEAB308);
  static const Color _tierGray = Color(0xFF6B7280);

  Future<void> _loadBots() async {
    if (widget.sharedBots.isNotEmpty) {
      setState(() => _bots = List.from(widget.sharedBots));
      return;
    }
    final baseUrl = await _prefs.backendBaseUrl;
    final token = await _prefs.authToken;
    final api = ApiClient(baseUrl, token: token);
    final resp = await api.getTradingBots();
    if (!mounted) return;
    setState(() => _bots = resp.botList);
  }

  Future<void> _loadAllEfficiency() async {
    if (_bots.isEmpty) {
      setState(() {
        _bundles = [];
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final loaded = await Future.wait(
        _bots.map((b) async {
          try {
            final r = await api.getStrategyDailyEfficiency(b.tradingbotId);
            return _BotEfficiencyBundle.fromLoad(b, r, null);
          } catch (e) {
            return _BotEfficiencyBundle.fromLoad(b, null, e.toString());
          }
        }),
      );
      if (!mounted) return;
      _applyTiers(loaded);
      setState(() {
        _bundles = loaded;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _bundles = [];
        _loading = false;
      });
    }
  }

  /// 按平均能效比值降序，三等分：前 1/3 绿、中 1/3 黄、后 1/3 灰。
  void _applyTiers(List<_BotEfficiencyBundle> list) {
    final scored = list.where((b) => b.hasEfficiencyData).toList()
      ..sort((a, b) => b.scoreForChart.compareTo(a.scoreForChart));
    final n = scored.length;
    for (var i = 0; i < n; i++) {
      scored[i].tier = _tierForRank(i, n);
    }
    for (final b in list) {
      if (!b.hasEfficiencyData) {
        b.tier = _EfficiencyTier.third;
      }
    }
  }

  static _EfficiencyTier _tierForRank(int rank, int n) {
    if (n <= 0) return _EfficiencyTier.third;
    if (n == 1) return _EfficiencyTier.first;
    if (n == 2) {
      return rank == 0 ? _EfficiencyTier.first : _EfficiencyTier.second;
    }
    final firstEnd = (n / 3).ceil();
    final secondEnd = (2 * n / 3).ceil();
    if (rank < firstEnd) return _EfficiencyTier.first;
    if (rank < secondEnd) return _EfficiencyTier.second;
    return _EfficiencyTier.third;
  }

  static Color _tierColor(_EfficiencyTier t) {
    switch (t) {
      case _EfficiencyTier.first:
        return _tierGreen;
      case _EfficiencyTier.second:
        return _tierYellow;
      case _EfficiencyTier.third:
        return _tierGray;
    }
  }

  static String _tierLabel(_EfficiencyTier t) {
    switch (t) {
      case _EfficiencyTier.first:
        return '一等';
      case _EfficiencyTier.second:
        return '二等';
      case _EfficiencyTier.third:
        return '三等';
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
    await _loadAllEfficiency();
  }

  String _fmtOpt(double? v, {int digits = 2}) {
    if (v == null || !v.isFinite) return '—';
    return v.toStringAsFixed(digits);
  }

  /// 波动 |高−低| 数值细，表内用 ×1e9 取整展示。
  static String _fmtTrNano(double? v) {
    if (v == null || !v.isFinite) return '—';
    return (v * 1e9).round().toString();
  }

  /// 能效比可能很小，表内用科学计数法更易读。
  static String _fmtEfficiencyCell(double? v) {
    if (v == null || !v.isFinite) return '—';
    final a = v.abs();
    if (a == 0) return '0';
    if (a >= 1e-2) return v.toStringAsFixed(6);
    if (a >= 1e-6) return v.toStringAsFixed(8);
    return v.toStringAsExponential(2);
  }

  static String _fmtAxisEfficiency(double v) {
    if (!v.isFinite) return '';
    final a = v.abs();
    if (a >= 0.01 || a == 0) return v.toStringAsFixed(3);
    return v.toStringAsExponential(1);
  }

  static Widget _chartLegendRow(
    BuildContext context,
    Color color,
    String label, {
    bool isLine = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isLine)
          Container(
            width: 22,
            height: 3,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          )
        else
          Container(
            width: 12,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        const SizedBox(width: 8),
        Text(
          label,
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildTierLegend(BuildContext context) {
    return Wrap(
      spacing: 20,
      runSpacing: 8,
      children: [
        _tierLegendChip(context, _tierGreen, '一等（优）'),
        _tierLegendChip(context, _tierYellow, '二等（良）'),
        _tierLegendChip(context, _tierGray, '三等（待提升）'),
      ],
    );
  }

  static Widget _tierLegendChip(
    BuildContext context,
    Color color,
    String text,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
        ),
      ],
    );
  }

  static const List<Color> _comparisonLineColors = [
    Color(0xFF7EC850),
    Color(0xFF3B82F6),
    Color(0xFFEAB308),
    Color(0xFFEF4444),
    Color(0xFFA855F7),
    Color(0xFF14B8A6),
    Color(0xFFF97316),
    Color(0xFFEC4899),
  ];

  /// 全账户：按日期对齐的能效比值折线，便于发现长期走弱、需人工关注的账户。
  Widget _buildComparisonChart(BuildContext context) {
    final forChart = _bundles.where((b) => b.fetchOk && b.hasEfficiencyData).toList();
    if (forChart.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          '暂无可对比的能效数据（请检查各账户接口返回）',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 13),
        ),
      );
    }
    final daySet = <String>{};
    for (final b in forChart) {
      for (final r in b.response!.rows) {
        daySet.add(r.day);
      }
    }
    final allDays = daySet.toList()..sort();
    if (allDays.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          '暂无按日能效点',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 13),
        ),
      );
    }
    final dayToX = <String, int>{
      for (var i = 0; i < allDays.length; i++) allDays[i]: i,
    };
    double? minY;
    double? maxY;
    final lineBars = <LineChartBarData>[];
    final plottedBundles = <_BotEfficiencyBundle>[];
    for (var bi = 0; bi < forChart.length; bi++) {
      final bundle = forChart[bi];
      final byDay = {
        for (final r in bundle.response!.rows) r.day: r.efficiencyRatio,
      };
      final spots = <FlSpot>[];
      for (final day in allDays) {
        final ratio = byDay[day];
        if (ratio != null && ratio.isFinite) {
          spots.add(FlSpot(dayToX[day]!.toDouble(), ratio));
          final my = minY;
          final xy = maxY;
          minY = my == null ? ratio : math.min(ratio, my);
          maxY = xy == null ? ratio : math.max(ratio, xy);
        }
      }
      if (spots.length < 2) continue;
      final colorIdx = plottedBundles.length;
      plottedBundles.add(bundle);
      final c = _comparisonLineColors[colorIdx % _comparisonLineColors.length];
      lineBars.add(
        LineChartBarData(
          spots: spots,
          color: c,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }
    if (lineBars.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          '各账户有效能效点不足（至少需要 2 个交易日连成线）',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 13),
        ),
      );
    }
    var lo = minY ?? 0;
    var hi = maxY ?? 1;
    if (lo == hi) {
      lo -= 1e-9;
      hi += 1e-9;
    }
    final pad = (hi - lo) * 0.12;
    final chartMinY = lo - pad;
    final chartMaxY = hi + pad;
    if (chartMinY == chartMaxY) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          '能效 Y 轴范围无效',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 13),
        ),
      );
    }

    final labelStep = (allDays.length / 6).ceil().clamp(1, allDays.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (var bi = 0; bi < plottedBundles.length; bi++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 3,
                    decoration: BoxDecoration(
                      color: _comparisonLineColors[bi % _comparisonLineColors.length],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    plottedBundles[bi].bot.tradingbotName ??
                        plottedBundles[bi].bot.tradingbotId,
                    style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 11),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 280,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (allDays.length - 1).toDouble(),
              minY: chartMinY,
              maxY: chartMaxY,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (v) => FlLine(
                  color: Colors.white.withValues(alpha: 0.06),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                show: true,
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 52,
                    getTitlesWidget: (v, m) => Text(
                      _fmtAxisEfficiency(v),
                      style: TextStyle(
                        color: AppFinanceStyle.labelColor.withValues(alpha: 0.85),
                        fontSize: 9,
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: labelStep.toDouble(),
                    getTitlesWidget: (v, m) {
                      final i = v.round();
                      if (i < 0 || i >= allDays.length) {
                        return const SizedBox.shrink();
                      }
                      final d = allDays[i];
                      final short = d.length >= 10 ? d.substring(5) : d;
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          short,
                          style: TextStyle(
                            color: AppFinanceStyle.labelColor.withValues(alpha: 0.85),
                            fontSize: 9,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                enabled: true,
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) =>
                      AppFinanceStyle.cardBackground.withValues(alpha: 0.95),
                  tooltipPadding: const EdgeInsets.all(10),
                  getTooltipItems: (touchedSpots) {
                    return touchedSpots.map((s) {
                      final bar = s.barIndex;
                      if (bar < 0 || bar >= plottedBundles.length) {
                        return null;
                      }
                      final xi = s.x.round().clamp(0, allDays.length - 1);
                      final day = allDays[xi];
                      final name =
                          plottedBundles[bar].bot.tradingbotName ??
                              plottedBundles[bar].bot.tradingbotId;
                      return LineTooltipItem(
                        '$name · $day\n策略能效 ${_fmtAxisEfficiency(s.y)}',
                        TextStyle(
                          color: AppFinanceStyle.valueColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      );
                    }).whereType<LineTooltipItem>().toList();
                  },
                ),
              ),
              lineBarsData: lineBars,
            ),
          ),
        ),
      ],
    );
  }

  Widget _transposedMetricsTable(
    BuildContext context,
    List<StrategyDailyEfficiencyRow> rows,
  ) {
    if (rows.isEmpty) {
      return Text(
        '无日明细',
        style: AppFinanceStyle.labelTextStyle(context),
      );
    }
    const labelW = 100.0;
    const cellW = 88.0;
    final columnWidths = <int, TableColumnWidth>{
      0: const FixedColumnWidth(labelW),
      for (var i = 0; i < rows.length; i++) i + 1: const FixedColumnWidth(cellW),
    };
    final hdrStyle = TextStyle(
      color: AppFinanceStyle.valueColor,
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );
    final labStyle = AppFinanceStyle.labelTextStyle(context).copyWith(
      fontSize: 11,
    );
    final valStyle = TextStyle(
      color: AppFinanceStyle.valueColor,
      fontSize: 11,
    );

    TableRow row(List<Widget> cells) => TableRow(children: cells);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        columnWidths: columnWidths,
        border: TableBorder.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.5,
        ),
        children: [
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Text('指标', style: hdrStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                child: Text(
                  e.day,
                  style: hdrStyle,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('波动×1e9', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtTrNano(e.tr),
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('每日波动率%', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtOpt(e.trPct),
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('当日现金增量 USDT', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtOpt(e.cashDeltaUsdt),
                  style: valStyle.copyWith(
                    color: (e.cashDeltaUsdt ?? 0) > 0
                        ? AppFinanceStyle.profitGreenEnd
                        : AppFinanceStyle.valueColor,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('UTC 月初基准 USDT', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  e.monthStartCash != null
                      ? _fmtOpt(e.monthStartCash)
                      : '—',
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('现金收益率%', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtOpt(e.cashDeltaPct, digits: 1),
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('策略能效', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtEfficiencyCell(e.efficiencyRatio),
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildOneAccountCard(BuildContext context, _BotEfficiencyBundle bundle) {
    final title = bundle.bot.tradingbotName ?? bundle.bot.tradingbotId;
    if (!bundle.fetchOk) {
      return FinanceCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _tierColor(bundle.tier),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppFinanceStyle.valueColor,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              bundle.fetchError ?? '加载失败',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
      );
    }
    final eff = bundle.response!;
    if (!eff.success) {
      return FinanceCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _tierColor(bundle.tier),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppFinanceStyle.valueColor,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                Text(
                  _tierLabel(bundle.tier),
                  style: TextStyle(
                    color: _tierColor(bundle.tier),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
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
        : '非 Account_List 账户无现金快照列；仍显示 OKX 日线波动。';

    return FinanceCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: _tierColor(bundle.tier),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppFinanceStyle.valueColor,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              Text(
                '${_tierLabel(bundle.tier)} · 均比 ${_fmtEfficiencyCell(bundle.hasEfficiencyData ? bundle.scoreForChart : null)}',
                style: TextStyle(
                  color: _tierColor(bundle.tier),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${eff.instId}：每日波动率% = |最高−最低|÷收盘×100；'
            '现金收益率% = 当日现金增量 USDT ÷ 当 UTC 自然月月初资金×100（无月初快照时用当日日初 sod）；'
            '策略能效 = 当日现金增量 USDT ÷ 价格波幅 ×1e-7。'
            '$cashNote',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
          ),
          const SizedBox(height: 12),
          DefaultTabController(
            length: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TabBar(
                  labelColor: AppFinanceStyle.valueColor,
                  unselectedLabelColor:
                      AppFinanceStyle.labelColor.withValues(alpha: 0.65),
                  indicatorColor: AppFinanceStyle.profitGreenEnd,
                  indicatorSize: TabBarIndicatorSize.label,
                  tabs: const [
                    Tab(text: '曲线'),
                    Tab(text: '数据'),
                  ],
                ),
                SizedBox(
                  height: 460,
                  child: TabBarView(
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 16,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _chartLegendRow(
                                context,
                                const Color.fromRGBO(245, 245, 245, 0.9),
                                '每日波动率%（柱：白/黄/红）',
                              ),
                              _chartLegendRow(
                                context,
                                const Color.fromRGBO(126, 200, 80, 0.88),
                                '现金收益率%（柱：<0.5%灰 0.5–1%白 ≥1%绿）',
                              ),
                              _chartLegendRow(
                                context,
                                const Color.fromRGBO(234, 179, 8, 0.95),
                                '现金收益率%（线，阈值同柱）',
                                isLine: true,
                              ),
                              _chartLegendRow(
                                context,
                                const Color(0xFFFBBF24),
                                '策略能效',
                                isLine: true,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          StrategyEfficiencyLightweightChart(rows: rows, height: 360),
                          Text(
                            '图表：TradingView Lightweight Charts',
                            style: AppFinanceStyle.labelTextStyle(context)
                                .copyWith(fontSize: 11),
                          ),
                        ],
                      ),
                      ListView(
                        padding: const EdgeInsets.only(top: 12),
                        children: [
                          Text(
                            '日明细（日期为列；现金收益率% 一位小数；「UTC 月初基准」有值表示收益率按月初资金计算）',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  color: AppFinanceStyle.valueColor,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: 8),
                          _transposedMetricsTable(context, rows),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _sortedAccountSections(BuildContext context) {
    final copy = List<_BotEfficiencyBundle>.from(_bundles);
    int tierOrder(_EfficiencyTier t) {
      switch (t) {
        case _EfficiencyTier.first:
          return 0;
        case _EfficiencyTier.second:
          return 1;
        case _EfficiencyTier.third:
          return 2;
      }
    }

    copy.sort((a, b) {
      final c = tierOrder(a.tier).compareTo(tierOrder(b.tier));
      if (c != 0) return c;
      return b.scoreForChart.compareTo(a.scoreForChart);
    });
    return copy.map((b) => _buildOneAccountCard(context, b)).toList();
  }

  /// 账户卡片之间插入间距，末尾不留空白间隔。
  Iterable<Widget> _accountCardsWithSpacing(BuildContext context) {
    final sections = _sortedAccountSections(context);
    if (sections.isEmpty) return const [];
    return sections.asMap().entries.expand((e) {
      final i = e.key;
      final w = e.value;
      if (i < sections.length - 1) {
        return [w, const SizedBox(height: 20)];
      }
      return [w];
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: RefreshIndicator(
          onRefresh: () async {
            await _loadBots();
            await _loadAllEfficiency();
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (_loadError != null)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                  sliver: SliverToBoxAdapter(
                    child: FinanceCard(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _loadError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
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
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      FinanceCard(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '全账户策略能效对比',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: AppFinanceStyle.labelColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '按时间对比各账户「策略能效」（当日现金增量 USDT ÷ 当日价格波幅 × 1e-7）。'
                              '折线持续走弱或长期垫底可优先人工干预。账户卡片上的绿/黄/灰仍表示相对排名。',
                              style: AppFinanceStyle.labelTextStyle(context)
                                  .copyWith(fontSize: 12),
                            ),
                            const SizedBox(height: 12),
                            _buildTierLegend(context),
                            const SizedBox(height: 16),
                            _buildComparisonChart(context),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      ..._accountCardsWithSpacing(context),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
