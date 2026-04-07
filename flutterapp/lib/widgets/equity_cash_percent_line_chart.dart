import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import 'month_end_profit_panel.dart' show dailyPerfChangeMapForMonth;

/// 深色背景上 X 轴日期刻度（与日历无数据格同档可读性）。
const _kChartAxisDateLabel = AppFinanceStyle.textDefault;

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

/// 单序列：相对首条快照 `initial_balance` 的收益率（%）。
enum SnapshotReturnSeries { equity, cash }

/// 权益或现金其中一条收益率折线（用于三列栅格左格）。
class SnapshotPercentLineChart extends StatelessWidget {
  const SnapshotPercentLineChart({
    super.key,
    required this.snapshots,
    required this.series,
    this.compact = false,
    /// 非空时仅展示该自然月内的快照点（与月度日历/柱图对齐）。
    this.focusedMonth,
    /// 与 [focusedMonth] 同月时优先使用：`累计(equity_change|cash_change) / 月初分母 * 100`（与 account_daily_performance 一致）。
    this.dailyPerfDays,
    /// 权益用月初权益；现金用 `month_initial_balance`（USDT 余额）。
    this.monthPerformanceDenom,
  });

  final List<BotProfitSnapshot> snapshots;
  final SnapshotReturnSeries series;
  final bool compact;
  final DateTime? focusedMonth;
  final List<DailyRealizedPnlDayRow>? dailyPerfDays;
  final double? monthPerformanceDenom;

  @override
  Widget build(BuildContext context) {
    final fullSorted = _sortedByTime(snapshots);
    final pickCh0 = series == SnapshotReturnSeries.equity
        ? (DailyRealizedPnlDayRow r) => r.equityChange
        : (DailyRealizedPnlDayRow r) => r.cashChange;
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

    int? lastDayInMonth;
    int? monthForAxis;
    var monthLineFromDailyPerf = false;
    var monthPerfMapForTip = <int, double>{};
    var monthLineDenomForTip = 0.0;
    final pick = series == SnapshotReturnSeries.equity
        ? (BotProfitSnapshot s) => s.equityUsdt
        : (BotProfitSnapshot s) => s.currentBalance;

    if (monthMode) {
      final y = focusedMonth!.year;
      final m = focusedMonth!.month;
      monthForAxis = m;
      final daysInMonth = DateTime(y, m + 1, 0).day;
      lastDayInMonth = daysInMonth;
      final pickCh = series == SnapshotReturnSeries.equity
          ? (DailyRealizedPnlDayRow r) => r.equityChange
          : (DailyRealizedPnlDayRow r) => r.cashChange;
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
        monthLineDenomForTip = monthDenom;
        var cum = 0.0;
        for (var day = 1; day <= daysInMonth; day++) {
          cum += perfMap[day] ?? 0.0;
          final pct = (cum / monthDenom) * 100;
          spots.add(FlSpot((day - 1).toDouble(), pct));
          if (pct < minY) minY = pct;
          if (pct > maxY) maxY = pct;
        }
      } else {
        final beforeFirstDay =
            DateTime(y, m, 1).subtract(const Duration(microseconds: 1));
        double? runCarry;
        final startVal = _snapshotValueAtOrBefore(fullSorted, beforeFirstDay, pick);
        if (startVal.isFinite) runCarry = startVal;

        for (var day = 1; day <= daysInMonth; day++) {
          final end = DateTime(y, m, day, 23, 59, 59, 999);
          final vRaw = _snapshotValueAtOrBefore(fullSorted, end, pick);
          late final double v;
          if (vRaw.isFinite) {
            runCarry = vRaw;
            v = vRaw;
          } else if (runCarry != null) {
            v = runCarry;
          } else if (startVal.isFinite) {
            v = startVal;
          } else {
            // 整月无 prior 快照时仍铺满 X 轴，收益率按 0% 水平线展示
            v = denom;
          }
          final pct = (v / denom - 1) * 100;
          spots.add(FlSpot((day - 1).toDouble(), pct));
          if (pct < minY) minY = pct;
          if (pct > maxY) maxY = pct;
        }
      }
    } else {
      for (var i = 0; i < sorted.length; i++) {
        final s = sorted[i];
        final pct = series == SnapshotReturnSeries.equity
            ? (s.equityUsdt / denom - 1) * 100
            : (s.currentBalance / denom - 1) * 100;
        spots.add(FlSpot(i.toDouble(), pct));
        if (pct < minY) minY = pct;
        if (pct > maxY) maxY = pct;
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

    final xSpan = monthMode
        ? ((lastDayInMonth ?? 1) - 1).clamp(0, 999).toDouble()
        : (sorted.length - 1).clamp(0, double.infinity).toDouble();
    final xLabelIdx = monthMode
        ? _lineChartXLabelIndices(lastDayInMonth ?? 1)
        : _lineChartXLabelIndices(sorted.length);

    final chart = LineChart(
      LineChartData(
        minX: 0,
        maxX: xSpan,
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: const FlGridData(show: false),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                if (monthMode && monthForAxis != null && lastDayInMonth != null) {
                  final day = spot.x.round().clamp(0, lastDayInMonth - 1) + 1;
                  final y = focusedMonth!.year;
                  final mo = focusedMonth!.month;
                  if (monthLineFromDailyPerf) {
                    var cumTip = 0.0;
                    for (var d = 1; d <= day; d++) {
                      cumTip += monthPerfMapForTip[d] ?? 0.0;
                    }
                    final level = monthLineDenomForTip + cumTip;
                    final amt = formatUiInteger(level);
                    return LineTooltipItem(
                      '$day日 $amt（${formatUiInteger(spot.y)}%）',
                      TextStyle(
                        color: lineColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    );
                  }
                  final end = DateTime(y, mo, day, 23, 59, 59, 999);
                  final raw = _snapshotValueAtOrBefore(fullSorted, end, pick);
                  final amt =
                      raw.isFinite ? formatUiInteger(raw) : '—';
                  return LineTooltipItem(
                    '$day日 $amt（${formatUiInteger(spot.y)}%）',
                    TextStyle(
                      color: lineColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  );
                }
                final idx = spot.x.round().clamp(0, sorted.length - 1);
                final d = _parseSnapshotAt(sorted[idx].snapshotAt);
                final head =
                    d == null ? '' : '${d.month}/${d.day} ';
                return LineTooltipItem(
                  '$head${formatUiInteger(spot.y)}%',
                  TextStyle(
                    color: lineColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
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
              reservedSize: compact ? 30 : 36,
              interval: 1,
              getTitlesWidget: (v, meta) {
                return Text(
                  '${formatUiInteger(v)}%',
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
                  final ld = lastDayInMonth ?? 1;
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
          series == SnapshotReturnSeries.equity ? '权益收益率 %' : '现金收益率 %',
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
