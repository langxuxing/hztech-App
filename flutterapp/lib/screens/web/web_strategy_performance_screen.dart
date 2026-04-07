import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../utils/number_display_format.dart';
import '../../widgets/strategy_efficiency_lightweight_chart.dart';
import '../../widgets/water_background.dart';

enum _EffBarHatchPattern { diagonal, grid }

class _EffBarPatternLegendPainter extends CustomPainter {
  const _EffBarPatternLegendPainter({
    required this.pattern,
    required this.baseColor,
  });

  final _EffBarHatchPattern pattern;
  final Color baseColor;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(2),
    );
    canvas.drawRRect(r, Paint()..color = baseColor);
    canvas.save();
    canvas.clipRRect(r);
    final w = size.width;
    final h = size.height;
    if (pattern == _EffBarHatchPattern.grid) {
      final g1 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.4);
      final g2 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.22);
      for (var g = 0.0; g <= w; g += w / 3) {
        canvas.drawLine(Offset(0, g), Offset(w, g), g1);
        canvas.drawLine(Offset(g, 0), Offset(g, h), g1);
      }
      final border = RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5, 0.5, w - 1, h - 1),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(border, g2);
    } else {
      final d1 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.22);
      final d2 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.14);
      for (var o = -w; o <= w; o += 4.0) {
        canvas.drawLine(Offset(o, 0), Offset(o + w, h), d1);
      }
      for (var o = -h; o <= w; o += 4.0) {
        canvas.drawLine(Offset(o, h), Offset(o + w, 0), d2);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EffBarPatternLegendPainter oldDelegate) {
    return oldDelegate.pattern != pattern || oldDelegate.baseColor != baseColor;
  }
}

/// Web：策略效能——每日波动率、现金收益率%（较 UTC 月初）、策略能效，全账户同页对比（日线波动全站共用缓存）。
class WebStrategyPerformanceScreen extends StatefulWidget {
  const WebStrategyPerformanceScreen({super.key, this.sharedBots = const []});

  final List<UnifiedTradingBot> sharedBots;

  @override
  State<WebStrategyPerformanceScreen> createState() =>
      _WebStrategyPerformanceScreenState();
}

/// 策略能效分档（按账户均能效绝对阈值）：小于 0.25 灰、0.25–0.5 绿、≥0.5 深绿。
enum _EffBand { gray, green, darkGreen }

class _BotEfficiencyBundle {
  _BotEfficiencyBundle({required this.bot, this.response, this.fetchError});

  final UnifiedTradingBot bot;
  final StrategyDailyEfficiencyResponse? response;
  final String? fetchError;
  _EffBand band = _EffBand.gray;
  double scoreForChart = 0;

  bool get fetchOk => fetchError == null;
  bool get hasEfficiencyData =>
      response != null && response!.success && response!.rows.isNotEmpty;

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

  static _EffBand bandForScore(double? v) {
    if (v == null || !v.isFinite) return _EffBand.gray;
    if (v < 0.25) return _EffBand.gray;
    if (v < 0.5) return _EffBand.green;
    return _EffBand.darkGreen;
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

  /// 与后端 `strategy-daily-efficiency` 默认一致：约最近一个月（31 天），按日一条。
  static const int _efficiencyDays = 31;

  /// 按 UTC 日期升序后仅保留末尾 [maxDays] 条，保证图表/表格与「最近一月」窗口一致。
  static List<StrategyDailyEfficiencyRow> _limitRowsToRecentDays(
    List<StrategyDailyEfficiencyRow> rows,
    int maxDays,
  ) {
    if (rows.isEmpty) return [];
    final copy = List<StrategyDailyEfficiencyRow>.from(rows)
      ..sort((a, b) => a.day.compareTo(b.day));
    if (copy.length <= maxDays) return copy;
    return copy.sublist(copy.length - maxDays);
  }

  static const Color _bandGray = Color(0xFF6B7280);
  static const Color _bandGreen = Color(0xFF4ADE80);
  static const Color _bandDarkGreen = Color(0xFF166534);

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
            final r = await api.getStrategyDailyEfficiency(
              b.tradingbotId,
              days: _efficiencyDays,
            );
            return _BotEfficiencyBundle.fromLoad(b, r, null);
          } catch (e) {
            return _BotEfficiencyBundle.fromLoad(b, null, e.toString());
          }
        }),
      );
      if (!mounted) return;
      _applyEffBands(loaded);
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

  void _applyEffBands(List<_BotEfficiencyBundle> list) {
    for (final b in list) {
      b.band = _BotEfficiencyBundle.bandForScore(
        b.hasEfficiencyData ? b.scoreForChart : null,
      );
    }
  }

  static Color _bandColor(_EffBand t) {
    switch (t) {
      case _EffBand.gray:
        return _bandGray;
      case _EffBand.green:
        return _bandGreen;
      case _EffBand.darkGreen:
        return _bandDarkGreen;
    }
  }

  static String _bandLabel(_EffBand t) {
    switch (t) {
      case _EffBand.gray:
        return '偏低';
      case _EffBand.green:
        return '中等';
      case _EffBand.darkGreen:
        return '优良';
    }
  }

  static Color _efficiencyPointColor(double? v) {
    if (v == null || !v.isFinite) return _bandGray;
    if (v < 0.25) return _bandGray;
    if (v < 0.5) return _bandGreen;
    return _bandDarkGreen;
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

  /// 金额类：表内展示为整数。
  static String _fmtIntAmount(double? v) {
    if (v == null || !v.isFinite) return '—';
    return v.round().toString();
  }

  /// 价格波幅 |高−低|：×1e9 后取整展示。
  static String _fmtTrNano(double? v) {
    if (v == null || !v.isFinite) return '—';
    return (v * 1e9).round().toString();
  }

  /// 每日波动率%：取整 + `%`。
  static String _fmtVolatilityPctInt(double? v) {
    if (v == null || !v.isFinite) return '—';
    return '${v.round()}%';
  }

  /// 百分数类指标：一位小数 + `%`（与盈亏% 展示习惯一致）。
  static String _fmtPctOneLabel(double? v) {
    if (v == null || !v.isFinite) return '—';
    return '${v.toStringAsFixed(1)}%';
  }

  /// 策略能效：界面与其它数值一致，四舍五入为整数。
  static String _fmtEfficiencyCell(double? v) => formatUiIntegerOpt(v);

  static String _fmtAxisEfficiency(double v) {
    if (!v.isFinite) return '';
    return formatUiInteger(v);
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

  /// 与 Lightweight Charts 内柱形图纹一致：波动率斜纹、现金收益率网格。
  static Widget _chartBarPatternLegendRow(
    BuildContext context, {
    required _EffBarHatchPattern pattern,
    required Color baseColor,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 14,
          child: CustomPaint(
            painter: _EffBarPatternLegendPainter(
              pattern: pattern,
              baseColor: baseColor,
            ),
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

  Widget _buildBandLegend(BuildContext context) {
    return Wrap(
      spacing: 20,
      runSpacing: 8,
      children: [
        _bandLegendChip(context, _bandGray, '偏低（能效<0.25）'),
        _bandLegendChip(context, _bandGreen, '中等（0.25–0.5）'),
        _bandLegendChip(context, _bandDarkGreen, '优良（≥0.5）'),
      ],
    );
  }

  static Widget _bandLegendChip(
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
    final forChart = _bundles
        .where((b) => b.fetchOk && b.hasEfficiencyData)
        .toList();
    if (forChart.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
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
    var allDays = daySet.toList()..sort();
    if (allDays.length > _efficiencyDays) {
      allDays = allDays.sublist(allDays.length - _efficiencyDays);
    }
    if (allDays.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Text(
          '能效 Y 轴范围无效',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 13),
        ),
      );
    }

    final labelStep = allDays.length <= 31
        ? 1
        : (allDays.length / 6).ceil().clamp(1, allDays.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(
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
                        color:
                            _comparisonLineColors[bi %
                                _comparisonLineColors.length],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      plottedBundles[bi].bot.tradingbotName ??
                          plottedBundles[bi].bot.tradingbotId,
                      style: AppFinanceStyle.labelTextStyle(
                        context,
                      ).copyWith(fontSize: 11),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SizedBox(
            width: double.infinity,
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
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 52,
                      getTitlesWidget: (v, m) => Text(
                        _fmtAxisEfficiency(v),
                        style: TextStyle(
                          color: AppFinanceStyle.labelColor.withValues(
                            alpha: 0.85,
                          ),
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
                              color: AppFinanceStyle.labelColor.withValues(
                                alpha: 0.85,
                              ),
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
                      return touchedSpots
                          .map((s) {
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
                          })
                          .whereType<LineTooltipItem>()
                          .toList();
                    },
                  ),
                ),
                lineBarsData: lineBars,
              ),
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
      return Text('无日明细', style: AppFinanceStyle.labelTextStyle(context));
    }
    const labelW = 100.0;
    const cellW = 88.0;
    final columnWidths = <int, TableColumnWidth>{
      0: const FixedColumnWidth(labelW),
      for (var i = 0; i < rows.length; i++)
        i + 1: const FixedColumnWidth(cellW),
    };
    final hdrStyle = TextStyle(
      color: AppFinanceStyle.valueColor,
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );
    final labStyle = AppFinanceStyle.labelTextStyle(
      context,
    ).copyWith(fontSize: 11);
    final valStyle = TextStyle(color: AppFinanceStyle.valueColor, fontSize: 11);

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
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 10,
                ),
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
                  _fmtVolatilityPctInt(e.trPct),
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('当日现金增量', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtIntAmount(e.cashDeltaUsdt),
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
              child: Text('月初资金', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  e.monthStartCash != null
                      ? _fmtIntAmount(e.monthStartCash)
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
                  _fmtPctOneLabel(e.cashDeltaPct),
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('月初权益', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  e.monthStartEquity != null
                      ? _fmtIntAmount(e.monthStartEquity)
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
              child: Text('权益收益率%', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtPctOneLabel(e.equityDeltaPct),
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
                  style: valStyle.copyWith(
                    color: _efficiencyPointColor(e.efficiencyRatio),
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('权益能效', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtEfficiencyCell(e.equityEfficiencyRatio),
                  style: valStyle.copyWith(
                    color: _efficiencyPointColor(e.equityEfficiencyRatio),
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('ATR14', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  e.atr14 != null ? e.atr14!.toStringAsFixed(8) : '—',
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

  Widget _buildOneAccountCard(
    BuildContext context,
    _BotEfficiencyBundle bundle,
  ) {
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
                    color: _bandColor(bundle.band),
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
                    color: _bandColor(bundle.band),
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
                  _bandLabel(bundle.band),
                  style: TextStyle(
                    color: _bandColor(bundle.band),
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
    final rows = _limitRowsToRecentDays(eff.rows, _efficiencyDays);
    // cash_basis：account_snapshots_cash 为历史枚举名；服务端数据来自表 account_balance_snapshots。
    final cashNote = switch (eff.cashBasis) {
      'account_snapshots_cash' => '现金变动来自（availEq），按自然日汇总。',
      'bot_profit_equity' => '日权益变动来自（equity），与收益曲线同源；按自然日汇总。',
      _ => '无历史快照：按 K 线日期补零增量，现金收益率% 与策略能效在无分母处为「—」或 0。',
    };

    return FinanceCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 5),
                decoration: BoxDecoration(
                  color: _bandColor(bundle.band),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: AppFinanceStyle.valueColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 22,
                        letterSpacing: -0.3,
                      ),
                ),
              ),
              Text(
                '${_bandLabel(bundle.band)} · 均比 ${_fmtEfficiencyCell(bundle.hasEfficiencyData ? bundle.scoreForChart : null)}',
                style: TextStyle(
                  color: _bandColor(bundle.band),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '${eff.instId}：每日波动率% = |最高−最低|÷收盘 × 100%；'
            '策略/权益能效 = 当日增量÷（最高−最低） × 1e9；',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
              fontSize: 13,
              height: 1.45,
              color: AppFinanceStyle.textDefault.withValues(alpha: 0.58),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            cashNote,
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
              fontSize: 12,
              height: 1.4,
              color: AppFinanceStyle.textDefault.withValues(alpha: 0.42),
            ),
          ),
          const SizedBox(height: 16),
          DefaultTabController(
            length: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  color: Colors.transparent,
                  child: DecoratedBox(
                    decoration:
                        AppFinanceStyle.webSubtleInsetPanelDecoration(),
                    child: TabBar(
                      labelColor: AppFinanceStyle.profitGreenEnd,
                      unselectedLabelColor:
                          AppFinanceStyle.labelColor.withValues(
                        alpha: 0.55,
                      ),
                      labelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      indicatorColor: AppFinanceStyle.profitGreenEnd,
                      indicatorWeight: 2.5,
                      indicatorSize: TabBarIndicatorSize.tab,
                      overlayColor:
                          WidgetStateProperty.all(Colors.transparent),
                      tabs: const [
                        Tab(text: '图表'),
                        Tab(text: '数据'),
                      ],
                    ),
                  ),
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
                              _chartBarPatternLegendRow(
                                context,
                                pattern: _EffBarHatchPattern.diagonal,
                                baseColor: const Color.fromRGBO(
                                  245,
                                  245,
                                  245,
                                  0.58,
                                ),
                                label:
                                    '每日波动率%（上半轴柱，斜纹；着色：白/黄/红 <6% / 6–10% / >10%）',
                              ),
                              _chartBarPatternLegendRow(
                                context,
                                pattern: _EffBarHatchPattern.grid,
                                baseColor: const Color.fromRGBO(
                                  34,
                                  197,
                                  94,
                                  0.62,
                                ),
                                label:
                                    '现金收益率%（下半轴柱，网格；着色：灰/白/绿 <0.5% / 0.5–1% / ≥1%）',
                              ),
                              _chartLegendRow(
                                context,
                                const Color(0xFF6B7280),
                                '策略能效折线（右轴；灰/绿/深绿：<0.25 / 0.25–0.5 / ≥0.5）',
                                isLine: true,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          StrategyEfficiencyLightweightChart(
                            rows: rows,
                            height: 360,
                          ),
                          Text(
                            '图表：TradingView Lightweight Charts',
                            style: AppFinanceStyle.labelTextStyle(
                              context,
                            ).copyWith(fontSize: 11),
                          ),
                        ],
                      ),
                      ListView(
                        padding: const EdgeInsets.only(top: 12),
                        children: [
                          Text(
                            '波动×1e9',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: const Color.fromARGB(
                                    255,
                                    208,
                                    208,
                                    216,
                                  ),
                                  fontWeight: FontWeight.w400,
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
    int bandOrder(_EffBand t) {
      switch (t) {
        case _EffBand.darkGreen:
          return 0;
        case _EffBand.green:
          return 1;
        case _EffBand.gray:
          return 2;
      }
    }

    copy.sort((a, b) {
      final c = bandOrder(a.band).compareTo(bandOrder(b.band));
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
        return [w, const SizedBox(height: 24)];
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
                  padding: EdgeInsets.fromLTRB(
                    24,
                    24 + AppFinanceStyle.webSummaryTitleSpacing,
                    24,
                    8,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1600),
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
                  padding: EdgeInsets.fromLTRB(
                    24,
                    24 + AppFinanceStyle.webSummaryTitleSpacing,
                    24,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1600),
                        child: FinanceCard(
                          padding: EdgeInsets.zero,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
                                child: Text(
                                  '全账户策略能效对比',
                                  style:
                                      (Theme.of(context).textTheme.titleLarge ??
                                              const TextStyle())
                                          .copyWith(
                                    color: AppFinanceStyle.labelColor,
                                    fontSize: (Theme.of(context)
                                                .textTheme
                                                .titleLarge
                                                ?.fontSize ??
                                            22) +
                                        2,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(22, 0, 22, 12),
                                child: Text(
                                  '默认展示最近约一个月（31 天、按 UTC 自然日）各账户「策略能效」'
                                  '（当日现金增量 ÷ (价格波幅×1e9)）。'
                                  '折线持续走弱，需要交易员人工干预。',
                                  style: AppFinanceStyle.labelTextStyle(
                                    context,
                                  ).copyWith(
                                    fontSize: 13,
                                    height: 1.4,
                                    color: AppFinanceStyle.textDefault
                                        .withValues(alpha: 0.55),
                                  ),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(22, 0, 22, 16),
                                child: _buildBandLegend(context),
                              ),
                              _buildComparisonChart(context),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate(
                      _accountCardsWithSpacing(context)
                          .map(
                            (w) => Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 1600),
                                child: w,
                              ),
                            ),
                          )
                          .toList(),
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
