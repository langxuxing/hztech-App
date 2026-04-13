import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import 'equity_cash_percent_line_chart.dart' show SnapshotReturnSeries;

/// Web 账号总览等：按自然月横轴展示 **权益或现金的绝对值**（USDT），非相对月初的「收益」差值。
///
/// 与 [SnapshotPercentLineChart] 的月内「收益」曲线分离，避免同一组件承担两种语义。
class EquityCashLineChart extends StatelessWidget {
  const EquityCashLineChart({
    super.key,
    required this.snapshots,
    required this.series,
    required this.focusedMonth,
    this.compact = true,
    /// 与总览卡片「月初」一致：有值时作为月初水位，在「上月末无快照」时仍能铺满当月横轴（与 [SnapshotPercentLineChart.monthOpenLevelHint] 对齐）。
    this.monthOpenLevelHint,
  });

  final List<BotProfitSnapshot> snapshots;
  final SnapshotReturnSeries series;
  final DateTime focusedMonth;
  final bool compact;
  final double? monthOpenLevelHint;

  @override
  Widget build(BuildContext context) {
    final fullSorted = _ecSortedByTime(snapshots);
    if (fullSorted.isEmpty) {
      return Center(
        child: Text(
          '暂无快照',
          style: TextStyle(
            color: AppFinanceStyle.labelColor,
            fontSize: compact ? 11 : 13,
          ),
        ),
      );
    }

    final y = focusedMonth.year;
    final m = focusedMonth.month;
    final monthForAxis = m;
    final daysInMonth = DateTime(y, m + 1, 0).day;
    final now = DateTime.now();
    final futureMonth =
        DateTime(y, m).isAfter(DateTime(now.year, now.month));
    /// 与 [MonthEndValueBarPanel] 按日柱一致：横轴覆盖整月。
    final axisLastDay = futureMonth ? 0 : daysInMonth;

    final pick = series == SnapshotReturnSeries.equity
        ? (BotProfitSnapshot s) => s.equityUsdt
        : (BotProfitSnapshot s) => s.cashBalance ?? s.currentBalance;

    final beforeFirstDay =
        DateTime(y, m, 1).subtract(const Duration(microseconds: 1));
    final startVal = _ecSnapshotValueAtOrBefore(fullSorted, beforeFirstDay, pick);

    final hint = monthOpenLevelHint;
    double? runCarry;
    if (hint != null && hint.isFinite) {
      runCarry = hint;
    }
    final spots = <FlSpot>[];
    var minY = 0.0;
    var maxY = 0.0;

    for (var day = 1; day <= axisLastDay; day++) {
      final end = DateTime(y, m, day, 23, 59, 59, 999);
      final vInMonth =
          _ecSnapshotValueAtOrBeforeInMonth(fullSorted, end, y, m, pick);
      late final double v;
      if (vInMonth.isFinite) {
        v = vInMonth;
        runCarry = vInMonth;
      } else if (runCarry != null) {
        v = runCarry;
      } else if (startVal.isFinite) {
        v = startVal;
        runCarry = startVal;
      } else {
        continue;
      }
      spots.add(FlSpot((day - 1).toDouble(), v));
      if (v < minY) minY = v;
      if (v > maxY) maxY = v;
    }

    if (spots.isEmpty) {
      return Center(
        child: Text(
          '该月无快照',
          style: TextStyle(
            color: AppFinanceStyle.labelColor,
            fontSize: compact ? 11 : 13,
          ),
        ),
      );
    }

    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }
    final pad = (maxY - minY).abs() * 0.08 + 1.0;
    final lineColor = _ecSnapshotTrendLineColor(spots);

    final monthPointCount = axisLastDay;
    final xSpan = (monthPointCount - 1).clamp(0, 999).toDouble();
    final xLabelIdx = _ecLineChartXLabelIndices(monthPointCount);

    final chart = LineChart(
      LineChartData(
        minX: 0,
        maxX: xSpan,
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: _kEcMonthAxisStep,
          getDrawingHorizontalLine: (v) => FlLine(
            color: Colors.white.withValues(alpha: 0.07),
            strokeWidth: 1,
          ),
        ),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => _kEcLineTouchTooltipBg,
            tooltipRoundedRadius: 8,
            tooltipPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            getTooltipItems: (touchedSpots) {
              const tipStyle = TextStyle(
                color: AppFinanceStyle.textDefault,
                fontWeight: FontWeight.w600,
                fontSize: 11,
              );
              final unitLabel =
                  series == SnapshotReturnSeries.equity ? '权益' : '现金';
              return touchedSpots.map((spot) {
                final day =
                    spot.x.round().clamp(0, monthPointCount - 1) + 1;
                return LineTooltipItem(
                  '$day日 $unitLabel ${formatUiInteger(spot.y)}',
                  tipStyle,
                );
              }).toList();
            },
          ),
        ),
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
              reservedSize: compact ? 34 : 40,
              interval: _kEcMonthAxisStep,
              getTitlesWidget: (v, meta) {
                if ((v -
                        (v / _kEcMonthAxisStep).round() * _kEcMonthAxisStep)
                    .abs() >
                    1e-2) {
                  return const SizedBox.shrink();
                }
                return Text(
                  formatUiInteger(v),
                  style: TextStyle(
                    color: AppFinanceStyle.labelColor.withValues(alpha: 0.85),
                    fontSize: compact ? 8 : 10,
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: compact ? 18 : 24,
              interval: 1,
              getTitlesWidget: (v, meta) {
                final ld = monthPointCount;
                if (ld <= 0) return const SizedBox.shrink();
                final i = v.round().clamp(0, ld - 1);
                if (!xLabelIdx.contains(i)) return const SizedBox.shrink();
                final t = '$monthForAxis/${i + 1}';
                return Padding(
                  padding: EdgeInsets.only(top: compact ? 2 : 4),
                  child: Text(
                    t,
                    style: TextStyle(
                      color: _kEcChartAxisDateLabel,
                      fontSize: compact ? 8 : 10,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: lineColor,
            barWidth: compact ? 2 : 2.5,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 150),
    );

    if (compact) {
      return SizedBox.expand(child: chart);
    }

    final foot = series == SnapshotReturnSeries.equity ? '权益（USDT）' : '现金（USDT）';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: chart),
        const SizedBox(height: 8),
        Text(
          foot,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppFinanceStyle.labelColor.withValues(alpha: 0.9),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

// --- 本文件内局部工具（与 equity_cash_percent_line_chart 逻辑对齐，避免跨文件耦合私有函数） ---

const _kEcChartAxisDateLabel = AppFinanceStyle.textDefault;
const _kEcMonthAxisStep = 500.0;
const _kEcLineTouchTooltipBg = Color(0xFF1E1E28);

Color _ecSnapshotTrendLineColor(List<FlSpot> spots) {
  if (spots.isEmpty) return AppFinanceStyle.chartProfit;
  return spots.last.y >= spots.first.y
      ? AppFinanceStyle.chartProfit
      : AppFinanceStyle.chartLoss;
}

DateTime? _ecParseSnapshotAt(String raw) {
  if (raw.isEmpty) return null;
  final s = raw.length >= 19 ? raw.substring(0, 19) : raw;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

List<BotProfitSnapshot> _ecSortedByTime(List<BotProfitSnapshot> raw) {
  final withDates = <({DateTime d, BotProfitSnapshot s})>[];
  for (final s in raw) {
    final d = _ecParseSnapshotAt(s.snapshotAt);
    if (d != null) withDates.add((d: d, s: s));
  }
  withDates.sort((a, b) => a.d.compareTo(b.d));
  return withDates.map((e) => e.s).toList();
}

double _ecSnapshotValueAtOrBefore(
  List<BotProfitSnapshot> sortedChronological,
  DateTime instant,
  double Function(BotProfitSnapshot s) pick,
) {
  double? v;
  for (final s in sortedChronological) {
    final d = _ecParseSnapshotAt(s.snapshotAt);
    if (d == null) continue;
    if (!d.isAfter(instant)) {
      v = pick(s);
    } else {
      break;
    }
  }
  return v ?? double.nan;
}

double _ecSnapshotValueAtOrBeforeInMonth(
  List<BotProfitSnapshot> sortedChronological,
  DateTime instant,
  int year,
  int month,
  double Function(BotProfitSnapshot s) pick,
) {
  double? v;
  for (final s in sortedChronological) {
    final d = _ecParseSnapshotAt(s.snapshotAt);
    if (d == null) continue;
    if (d.year != year || d.month != month) continue;
    if (!d.isAfter(instant)) {
      v = pick(s);
    } else {
      break;
    }
  }
  return v ?? double.nan;
}

Set<int> _ecLineChartXLabelIndices(int n) {
  if (n <= 0) return {};
  if (n <= 8) return Set<int>.from(List<int>.generate(n, (i) => i));
  const cap = 6;
  final s = <int>{0, n - 1};
  final step = (n - 1) / (cap - 1);
  for (var k = 1; k < cap - 1; k++) {
    s.add((k * step).round().clamp(1, n - 2));
  }
  return s;
}
