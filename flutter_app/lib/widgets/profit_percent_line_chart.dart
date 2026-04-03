import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/finance_style.dart';

/// 盈利率曲线：用 profitPercent 画线。
class ProfitPercentLineChart extends StatelessWidget {
  const ProfitPercentLineChart({super.key, required this.snapshots});

  final List<BotProfitSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) return const SizedBox.shrink();
    final spots = <FlSpot>[];
    double minY = 0, maxY = 0;
    for (var i = 0; i < snapshots.length; i++) {
      final p = snapshots[i].profitPercent;
      spots.add(FlSpot(i.toDouble(), p));
      if (p < minY) minY = p;
      if (p > maxY) maxY = p;
    }
    if (minY == maxY) {
      minY = minY - 1;
      maxY = maxY + 1;
    }
    final isPositive =
        snapshots.isNotEmpty && (snapshots.last.profitPercent >= 0);
    final lineColor = isPositive ? AppFinanceStyle.profitGreenEnd : Colors.red;
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (snapshots.length - 1).clamp(0, double.infinity).toDouble(),
        minY: minY - 2,
        maxY: maxY + 2,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: lineColor,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: (isPositive ? AppFinanceStyle.profitGreenEnd : Colors.red)
                  .withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 150),
    );
  }
}
