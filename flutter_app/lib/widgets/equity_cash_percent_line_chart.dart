import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/finance_style.dart';

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

/// 单序列：相对首条快照 `initial_balance` 的收益率（%）。
enum SnapshotReturnSeries { equity, cash }

/// 权益或现金其中一条收益率折线（用于三列栅格左格）。
class SnapshotPercentLineChart extends StatelessWidget {
  const SnapshotPercentLineChart({
    super.key,
    required this.snapshots,
    required this.series,
    this.compact = false,
  });

  final List<BotProfitSnapshot> snapshots;
  final SnapshotReturnSeries series;
  final bool compact;

  static const Color _cashLineColor = Color(0xFF7DB7FF);

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) {
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
    final sorted = _sortedByTime(snapshots);
    final denom = sorted.first.initialBalance;
    if (denom <= 0) {
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

    final spots = <FlSpot>[];
    var minY = 0.0;
    var maxY = 0.0;
    for (var i = 0; i < sorted.length; i++) {
      final s = sorted[i];
      final pct = series == SnapshotReturnSeries.equity
          ? (s.equityUsdt / denom - 1) * 100
          : (s.currentBalance / denom - 1) * 100;
      spots.add(FlSpot(i.toDouble(), pct));
      if (pct < minY) minY = pct;
      if (pct > maxY) maxY = pct;
    }
    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }
    final pad = (maxY - minY).abs() * 0.08 + 1.0;
    final lineColor = series == SnapshotReturnSeries.equity
        ? AppFinanceStyle.profitGreenEnd
        : _cashLineColor;

    final chart = LineChart(
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
      return chart;
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

  static const Color _cashLineColor = Color(0xFF7DB7FF);

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
                  color: AppFinanceStyle.profitGreenEnd,
                  barWidth: 2.5,
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: false),
                ),
                LineChartBarData(
                  spots: spotsCash,
                  isCurved: true,
                  color: _cashLineColor,
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
            _LegendDot(color: AppFinanceStyle.profitGreenEnd, label: '权益收益率'),
            const SizedBox(width: 20),
            _LegendDot(color: _cashLineColor, label: '现金收益率'),
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
