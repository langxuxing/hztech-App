import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';

int _daysInMonth(int y, int m) => DateTime(y, m + 1, 0).day;

Map<int, DailyRealizedPnlDayRow> _rowsByDayOfMonth(
  List<DailyRealizedPnlDayRow> days,
  int year,
  int month,
) {
  final out = <int, DailyRealizedPnlDayRow>{};
  for (final r in days) {
    final p = r.day.split('-');
    if (p.length != 3) continue;
    final yy = int.tryParse(p[0]);
    final mm = int.tryParse(p[1]);
    final dd = int.tryParse(p[2]);
    if (yy == year && mm == month && dd != null) {
      out[dd] = r;
    }
  }
  return out;
}

/// account_daily_performance：日已实现盈亏相对当月月初资金%（pnl_pct）
class DailyPerfPnlPctLineChart extends StatelessWidget {
  const DailyPerfPnlPctLineChart({
    super.key,
    required this.days,
    required this.year,
    required this.month,
  });

  final List<DailyRealizedPnlDayRow> days;
  final int year;
  final int month;

  @override
  Widget build(BuildContext context) {
    final last = _daysInMonth(year, month);
    final byDay = _rowsByDayOfMonth(days, year, month);
    final spots = <FlSpot>[];
    for (var d = 1; d <= last; d++) {
      final row = byDay[d];
      final v = row?.pnlPct;
      if (v != null && v.isFinite) {
        spots.add(FlSpot(d.toDouble(), v));
      }
    }
    if (spots.isEmpty) {
      return Center(
        child: Text(
          '暂无 pnl_pct 日数据',
          style: AppFinanceStyle.labelTextStyle(context),
          textAlign: TextAlign.center,
        ),
      );
    }
    var minY = spots.first.y;
    var maxY = spots.first.y;
    for (final s in spots) {
      minY = math.min(minY, s.y);
      maxY = math.max(maxY, s.y);
    }
    if (minY == maxY) {
      final pad = (maxY.abs() * 0.05 + 0.01).clamp(0.01, double.infinity);
      minY -= pad;
      maxY += pad;
    }
    final pad = (maxY - minY) * 0.12 + 0.01;
    final lineColor = spots.last.y >= spots.first.y
        ? AppFinanceStyle.chartProfit
        : AppFinanceStyle.chartLoss;
    return LineChart(
      LineChartData(
        minX: 1,
        maxX: last.toDouble(),
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touched) {
              return touched.map((t) {
                return LineTooltipItem(
                  '${t.x.toInt()}日 ${t.y.toStringAsFixed(3)}%',
                  TextStyle(
                    color: lineColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                );
              }).toList();
            },
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: lineColor,
            barWidth: 1.5,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: lineColor.withValues(alpha: 0.28),
            ),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 150),
    );
  }
}

/// 按日柱状图：有正负着色（net_pnl 或 cash_change）
class DailyPerfSignedBarChart extends StatelessWidget {
  const DailyPerfSignedBarChart({
    super.key,
    required this.days,
    required this.year,
    required this.month,
    required this.valueAt,
  });

  final List<DailyRealizedPnlDayRow> days;
  final int year;
  final int month;
  final double? Function(DailyRealizedPnlDayRow row) valueAt;

  @override
  Widget build(BuildContext context) {
    final last = _daysInMonth(year, month);
    final byDay = _rowsByDayOfMonth(days, year, month);
    var maxAbs = 1.0;
    final groups = <BarChartGroupData>[];
    for (var d = 1; d <= last; d++) {
      final row = byDay[d];
      final v = row == null ? null : valueAt(row);
      final vv = v ?? 0.0;
      if (vv.isFinite) {
        maxAbs = math.max(maxAbs, vv.abs());
      }
      final pos = vv >= 0;
      final c = pos ? AppFinanceStyle.chartProfit : AppFinanceStyle.chartLoss;
      groups.add(
        BarChartGroupData(
          x: d,
          barRods: [
            BarChartRodData(
              toY: vv,
              width: 5,
              color: c,
              borderRadius: BorderRadius.zero,
            ),
          ],
        ),
      );
    }
    final pad = maxAbs * 0.08 + 1.0;
    return BarChart(
      BarChartData(
        maxY: maxAbs + pad,
        minY: -maxAbs - pad,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final day = group.x;
              return BarTooltipItem(
                '$day日 ${formatUiInteger(rod.toY)}',
                TextStyle(
                  color: rod.color,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
              );
            },
          ),
        ),
        barGroups: groups,
      ),
      duration: const Duration(milliseconds: 150),
    );
  }
}

/// 日现金变动相对「月初 USDT 资产余额」的近似%（分母来自账户画像的 monthInitialBalance / 期初）
class DailyPerfCashChangePctLineChart extends StatelessWidget {
  const DailyPerfCashChangePctLineChart({
    super.key,
    required this.days,
    required this.year,
    required this.month,
    required this.monthBaseCash,
  });

  final List<DailyRealizedPnlDayRow> days;
  final int year;
  final int month;
  final double monthBaseCash;

  @override
  Widget build(BuildContext context) {
    final denom = monthBaseCash;
    if (denom <= 1e-12) {
      return Center(
        child: Text(
          '无月初资产余额分母，无法计算现金变动%',
          style: AppFinanceStyle.labelTextStyle(context),
          textAlign: TextAlign.center,
        ),
      );
    }
    final last = _daysInMonth(year, month);
    final byDay = _rowsByDayOfMonth(days, year, month);
    final spots = <FlSpot>[];
    for (var d = 1; d <= last; d++) {
      final ch = byDay[d]?.cashChange;
      if (ch != null && ch.isFinite) {
        spots.add(FlSpot(d.toDouble(), ch / denom * 100.0));
      }
    }
    if (spots.isEmpty) {
      return Center(
        child: Text(
          '暂无 cash_change 日数据',
          style: AppFinanceStyle.labelTextStyle(context),
          textAlign: TextAlign.center,
        ),
      );
    }
    var minY = spots.first.y;
    var maxY = spots.first.y;
    for (final s in spots) {
      minY = math.min(minY, s.y);
      maxY = math.max(maxY, s.y);
    }
    if (minY == maxY) {
      final pad = (maxY.abs() * 0.05 + 0.01).clamp(0.01, double.infinity);
      minY -= pad;
      maxY += pad;
    }
    final pad = (maxY - minY) * 0.12 + 0.01;
    final lineColor = spots.last.y >= spots.first.y
        ? AppFinanceStyle.chartProfit
        : AppFinanceStyle.chartLoss;
    return LineChart(
      LineChartData(
        minX: 1,
        maxX: last.toDouble(),
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touched) {
              return touched.map((t) {
                return LineTooltipItem(
                  '${t.x.toInt()}日 ${t.y.toStringAsFixed(3)}%',
                  TextStyle(
                    color: lineColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                );
              }).toList();
            },
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: lineColor,
            barWidth: 1.5,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: lineColor.withValues(alpha: 0.28),
            ),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 150),
    );
  }
}
