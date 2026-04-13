import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import 'month_end_profit_panel.dart' show dailyPerfChangeMapForMonth;

/// 深色背景上 X 轴日期刻度（与日历无数据格同档可读性）。
const _kChartAxisDateLabel = AppFinanceStyle.textDefault;

/// 月视图下权益/现金收益折线左轴与横向网格步长（USDT，与 Web「账户收益」、APK「本月收益」一致）。
const _kSnapshotMonthLineAxisStep = 500.0;

/// 折线触摸提示：不透明底色 + 浅色字，避免盈亏色与默认灰底糊在一起。
const _kLineTouchTooltipBg = Color(0xFF1E1E28);

/// 与日绩效折线一致：区间内末点相对首点涨跌着色。
Color _snapshotTrendLineColor(List<FlSpot> spots) {
  if (spots.isEmpty) return AppFinanceStyle.chartProfit;
  return spots.last.y >= spots.first.y
      ? AppFinanceStyle.chartProfit
      : AppFinanceStyle.chartLoss;
}

DateTime? _parseSnapshotAt(String raw) {
  if (raw.isEmpty) return null;
  final s = raw.length >= 19 ? raw.substring(0, 19) : raw;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

List<BotProfitSnapshot> _sortedByTime(List<BotProfitSnapshot> raw) {
  final withDates = <({DateTime d, BotProfitSnapshot s})>[];
  for (final s in raw) {
    final d = _parseSnapshotAt(s.snapshotAt);
    if (d != null) withDates.add((d: d, s: s));
  }
  withDates.sort((a, b) => a.d.compareTo(b.d));
  return withDates.map((e) => e.s).toList();
}

/// 使用按时间排序的全量快照：取 `instant` 当日及之前最后一条快照的字段值。
double _snapshotValueAtOrBefore(
  List<BotProfitSnapshot> sortedChronological,
  DateTime instant,
  double Function(BotProfitSnapshot s) pick,
) {
  double? v;
  for (final s in sortedChronological) {
    final d = _parseSnapshotAt(s.snapshotAt);
    if (d == null) continue;
    if (!d.isAfter(instant)) {
      v = pick(s);
    } else {
      break;
    }
  }
  return v ?? double.nan;
}

/// 仅使用 [year]/[month] 内的快照，避免「上月异常 equity」被当作本月初前值。
double _snapshotValueAtOrBeforeInMonth(
  List<BotProfitSnapshot> sortedChronological,
  DateTime instant,
  int year,
  int month,
  double Function(BotProfitSnapshot s) pick,
) {
  double? v;
  for (final s in sortedChronological) {
    final d = _parseSnapshotAt(s.snapshotAt);
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

/// X 轴刻度：点很多时只标若干处，避免重叠。
Set<int> _lineChartXLabelIndices(int n) {
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

/// 单序列：收益曲线（金额）。
enum SnapshotReturnSeries { equity, cash }

/// 权益或现金其中一条收益折线（用于三列栅格左格）。
class SnapshotPercentLineChart extends StatelessWidget {
  const SnapshotPercentLineChart({
    super.key,
    required this.snapshots,
    required this.series,
    this.compact = false,
    /// 非空时仅展示该自然月内的快照点（与月度日历/柱图对齐）。
    this.focusedMonth,
    /// 与 [focusedMonth] 同月时优先使用：`累计(equlity_changed|balance_changed)`（与 account_daily_performance 一致）。
    this.dailyPerfDays,
    /// 权益用月初权益；现金用 `month_initial_balance`（USDT 余额）。
    this.monthPerformanceDenom,
    /// 与界面「月初」一致：有值时作为当月收益曲线的基准水位，且日内取值不引用上月快照。
    this.monthOpenLevelHint,
  });

  final List<BotProfitSnapshot> snapshots;
  final SnapshotReturnSeries series;
  final bool compact;
  final DateTime? focusedMonth;
  final List<DailyRealizedPnlDayRow>? dailyPerfDays;
  final double? monthPerformanceDenom;
  final double? monthOpenLevelHint;

  @override
  Widget build(BuildContext context) {
    final fullSorted = _sortedByTime(snapshots);
    final pickCh0 = series == SnapshotReturnSeries.equity
        ? (DailyRealizedPnlDayRow r) => r.equlityChanged
        : (DailyRealizedPnlDayRow r) => r.balanceChanged;
    final perfEarly = focusedMonth != null &&
            dailyPerfDays != null &&
            monthPerformanceDenom != null &&
            monthPerformanceDenom! > 0
        ? dailyPerfChangeMapForMonth(
            dailyPerfDays!,
            focusedMonth!.year,
            focusedMonth!.month,
            pickCh0,
          )
        : <int, double>{};
    /// 无历史快照时，仅在有选中月 + 日绩效 + 月初分母 时仍可画月内折线。
    final allowEmptySnapshots = focusedMonth != null && perfEarly.isNotEmpty;

    if (fullSorted.isEmpty && !allowEmptySnapshots) {
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

    var sorted = fullSorted;
    if (focusedMonth != null && fullSorted.isNotEmpty) {
      final y = focusedMonth!.year;
      final m = focusedMonth!.month;
      final monthStart = DateTime(y, m, 1);
      final monthEnd = DateTime(y, m + 1, 0, 23, 59, 59, 999);
      sorted = fullSorted.where((s) {
        final d = _parseSnapshotAt(s.snapshotAt);
        if (d == null) return false;
        return !d.isBefore(monthStart) && !d.isAfter(monthEnd);
      }).toList();
    }

    final denom = fullSorted.isNotEmpty ? fullSorted.first.initialBalance : 1.0;
    if (fullSorted.isNotEmpty && denom <= 0) {
      return Center(
        child: Text(
          '期初为 0',
          style: TextStyle(
            color: AppFinanceStyle.labelColor,
            fontSize: compact ? 11 : 13,
          ),
        ),
      );
    }

    final monthMode = focusedMonth != null;
    final spots = <FlSpot>[];
    var minY = 0.0;
    var maxY = 0.0;

    int? monthForAxis;
    /// 与按日柱图横轴天数一致（含「未来月」为 0）。
    var monthAxisDayCount = 0;
    var monthLineFromDailyPerf = false;
    var monthPerfMapForTip = <int, double>{};
    final pick = series == SnapshotReturnSeries.equity
        ? (BotProfitSnapshot s) => s.equityUsdt
        : (BotProfitSnapshot s) => s.cashBalance ?? s.currentBalance;

    if (monthMode) {
      final y = focusedMonth!.year;
      final m = focusedMonth!.month;
      monthForAxis = m;
      final daysInMonth = DateTime(y, m + 1, 0).day;
      final now = DateTime.now();
      final futureMonth =
          DateTime(y, m).isAfter(DateTime(now.year, now.month));
      /// 与 [MonthEndValueBarPanel] 按日柱一致：横轴覆盖整月（未来月仍为 0）。
      final axisLastDay = futureMonth ? 0 : daysInMonth;
      monthAxisDayCount = axisLastDay;
      final pickCh = series == SnapshotReturnSeries.equity
          ? (DailyRealizedPnlDayRow r) => r.equlityChanged
          : (DailyRealizedPnlDayRow r) => r.balanceChanged;
      final perfMap = dailyPerfDays != null &&
              monthPerformanceDenom != null &&
              monthPerformanceDenom! > 0
          ? dailyPerfChangeMapForMonth(dailyPerfDays!, y, m, pickCh)
          : <int, double>{};
      final monthDenom = monthPerformanceDenom;
      final useDailyPerf =
          perfMap.isNotEmpty && monthDenom != null && monthDenom > 0;

      if (useDailyPerf) {
        monthLineFromDailyPerf = true;
        monthPerfMapForTip = perfMap;
        var cum = 0.0;
        for (var day = 1; day <= axisLastDay; day++) {
          cum += perfMap[day] ?? 0.0;
          spots.add(FlSpot((day - 1).toDouble(), cum));
          if (cum < minY) minY = cum;
          if (cum > maxY) maxY = cum;
        }
      } else {
        final beforeFirstDay =
            DateTime(y, m, 1).subtract(const Duration(microseconds: 1));
        final startVal = _snapshotValueAtOrBefore(fullSorted, beforeFirstDay, pick);
        double? firstInMonthVal;
        for (final s in fullSorted) {
          final d = _parseSnapshotAt(s.snapshotAt);
          if (d == null) continue;
          if (d.year == y && d.month == m) {
            firstInMonthVal = pick(s);
            break;
          }
        }
        final hint = monthOpenLevelHint;
        final monthBase = (hint != null && hint.isFinite)
            ? hint
            : (firstInMonthVal != null && firstInMonthVal.isFinite)
                ? firstInMonthVal
                : (startVal.isFinite ? startVal : denom);
        var runCarry = monthBase.isFinite ? monthBase : null;

        for (var day = 1; day <= axisLastDay; day++) {
          final end = DateTime(y, m, day, 23, 59, 59, 999);
          final vInMonth =
              _snapshotValueAtOrBeforeInMonth(fullSorted, end, y, m, pick);
          late final double v;
          if (vInMonth.isFinite) {
            v = vInMonth;
            runCarry = vInMonth;
          } else if (runCarry != null) {
            v = runCarry;
          } else if (startVal.isFinite) {
            v = startVal;
          } else {
            continue;
          }
          final profit = v - monthBase;
          spots.add(FlSpot((day - 1).toDouble(), profit));
          if (profit < minY) minY = profit;
          if (profit > maxY) maxY = profit;
        }
      }
    } else {
      for (var i = 0; i < sorted.length; i++) {
        final s = sorted[i];
        final profit = series == SnapshotReturnSeries.equity
            ? (s.equityUsdt - denom)
            : ((s.cashBalance ?? s.currentBalance) - denom);
        spots.add(FlSpot(i.toDouble(), profit));
        if (profit < minY) minY = profit;
        if (profit > maxY) maxY = profit;
      }
    }

    if (spots.isEmpty) {
      return Center(
        child: Text(
          focusedMonth != null ? '该月无快照' : '暂无快照',
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
    final lineColor = _snapshotTrendLineColor(spots);

    final monthPointCount = monthMode ? monthAxisDayCount : 0;
    final xSpan = monthMode
        ? (monthPointCount - 1).clamp(0, 999).toDouble()
        : (sorted.length - 1).clamp(0, double.infinity).toDouble();
    final xLabelIdx = monthMode
        ? _lineChartXLabelIndices(monthPointCount)
        : _lineChartXLabelIndices(sorted.length);

    final chart = LineChart(
      LineChartData(
        minX: 0,
        maxX: xSpan,
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: FlGridData(
          show: monthMode,
          drawVerticalLine: false,
          horizontalInterval: monthMode ? _kSnapshotMonthLineAxisStep : null,
          getDrawingHorizontalLine: (v) => FlLine(
            color: Colors.white.withValues(alpha: 0.07),
            strokeWidth: 1,
          ),
        ),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => _kLineTouchTooltipBg,
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
              return touchedSpots.map((spot) {
                if (monthMode && monthForAxis != null && monthPointCount > 0) {
                  final day = spot.x.round().clamp(0, monthPointCount - 1) + 1;
                  final vsMonth =
                      series == SnapshotReturnSeries.equity ? '权益' : '现金';
                  if (monthLineFromDailyPerf) {
                    var cumTip = 0.0;
                    for (var d = 1; d <= day; d++) {
                      cumTip += monthPerfMapForTip[d] ?? 0.0;
                    }
                    return LineTooltipItem(
                      '$day日 $vsMonth较月初 ${formatUiInteger(cumTip)}',
                      tipStyle,
                    );
                  }
                  return LineTooltipItem(
                    '$day日 $vsMonth较月初 ${formatUiInteger(spot.y)}',
                    tipStyle,
                  );
                }
                final idx = spot.x.round().clamp(0, sorted.length - 1);
                final d = _parseSnapshotAt(sorted[idx].snapshotAt);
                final head =
                    d == null ? '' : '${d.month}/${d.day} ';
                return LineTooltipItem(
                  '$head收益 ${formatUiInteger(spot.y)}',
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
              showTitles: monthMode,
              reservedSize: compact ? 34 : 40,
              interval: monthMode ? _kSnapshotMonthLineAxisStep : null,
              getTitlesWidget: (v, meta) {
                if (monthMode) {
                  if ((v -
                          (v / _kSnapshotMonthLineAxisStep).round() *
                              _kSnapshotMonthLineAxisStep)
                      .abs() >
                      1e-2) {
                    return const SizedBox.shrink();
                  }
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
                if (monthMode) {
                  final ld = monthPointCount;
                  if (ld <= 0) return const SizedBox.shrink();
                  final i = v.round().clamp(0, ld - 1);
                  if (!xLabelIdx.contains(i)) return const SizedBox.shrink();
                  final t = monthForAxis == null ? '' : '$monthForAxis/${i + 1}';
                  return Padding(
                    padding: EdgeInsets.only(top: compact ? 2 : 4),
                    child: Text(
                      t,
                      style: TextStyle(
                        color: _kChartAxisDateLabel,
                        fontSize: compact ? 8 : 10,
                      ),
                    ),
                  );
                }
                final nPts = sorted.length;
                if (nPts == 0) return const SizedBox.shrink();
                final i = v.round().clamp(0, nPts - 1);
                if (!xLabelIdx.contains(i)) return const SizedBox.shrink();
                final d = _parseSnapshotAt(sorted[i].snapshotAt);
                final t = d == null ? '' : '${d.month}/${d.day}';
                return Padding(
                  padding: EdgeInsets.only(top: compact ? 2 : 4),
                  child: Text(
                    t,
                    style: TextStyle(
                      color: _kChartAxisDateLabel,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: chart),
        const SizedBox(height: 8),
        Text(
          series == SnapshotReturnSeries.equity ? '权益收益' : '现金收益',
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

/// 权益与现金相对期初的收益率曲线（%，与快照顺序一致）。
class EquityCashPercentLineChart extends StatelessWidget {
  const EquityCashPercentLineChart({super.key, required this.snapshots});

  final List<BotProfitSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) return const SizedBox.shrink();
    final sorted = _sortedByTime(snapshots);
    final denom = sorted.first.initialBalance;
    if (denom <= 0) {
      return Center(
        child: Text(
          '期初为 0，无法计算收益率',
          style: TextStyle(color: AppFinanceStyle.labelColor, fontSize: 13),
        ),
      );
    }

    final spotsEq = <FlSpot>[];
    final spotsCash = <FlSpot>[];
    var minY = 0.0;
    var maxY = 0.0;
    for (var i = 0; i < sorted.length; i++) {
      final s = sorted[i];
      final eqPct = (s.equityUsdt / denom - 1) * 100;
      final cashPct = (s.currentBalance / denom - 1) * 100;
      spotsEq.add(FlSpot(i.toDouble(), eqPct));
      spotsCash.add(FlSpot(i.toDouble(), cashPct));
      for (final p in [eqPct, cashPct]) {
        if (p < minY) minY = p;
        if (p > maxY) maxY = p;
      }
    }
    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }
    final pad = (maxY - minY).abs() * 0.08 + 1.0;
    final eqColor = _snapshotTrendLineColor(spotsEq);
    final cashColor = _snapshotTrendLineColor(spotsCash);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (sorted.length - 1).clamp(0, double.infinity).toDouble(),
              minY: minY - pad,
              maxY: maxY + pad,
              gridData: const FlGridData(show: false),
              titlesData: const FlTitlesData(show: false),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: spotsEq,
                  isCurved: true,
                  color: eqColor,
                  barWidth: 2.5,
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: false),
                ),
                LineChartBarData(
                  spots: spotsCash,
                  isCurved: true,
                  color: cashColor,
                  barWidth: 2.5,
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: false),
                ),
              ],
            ),
            duration: const Duration(milliseconds: 150),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _LegendDot(color: eqColor, label: '权益收益率'),
            const SizedBox(width: 20),
            _LegendDot(color: cashColor, label: '现金收益率'),
          ],
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: AppFinanceStyle.labelColor.withValues(alpha: 0.9),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
