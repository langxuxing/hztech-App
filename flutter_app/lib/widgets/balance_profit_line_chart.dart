import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/finance_style.dart';

/// 现金余额曲线：用快照的 `currentBalance`（USDT）画线。
class CashBalanceLineChart extends StatelessWidget {
  const CashBalanceLineChart({super.key, required this.snapshots});

  final List<BotProfitSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) return const SizedBox.shrink();
    final spots = <FlSpot>[];
    final firstY = snapshots.first.currentBalance;
    var minY = firstY;
    var maxY = firstY;
    for (var i = 0; i < snapshots.length; i++) {
      final b = snapshots[i].currentBalance;
      spots.add(FlSpot(i.toDouble(), b));
      if (b < minY) minY = b;
      if (b > maxY) maxY = b;
    }
    if (minY == maxY) {
      final d = (firstY.abs() * 0.01).clamp(1.0, double.infinity);
      minY = minY - d;
      maxY = maxY + d;
    }
    final pad = (maxY - minY) * 0.08 + 1.0;
    final isPositive = snapshots.isNotEmpty &&
        (snapshots.last.currentBalance >= snapshots.first.currentBalance);
    final lineColor = isPositive ? AppFinanceStyle.profitGreenEnd : Colors.red;
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (snapshots.length - 1).clamp(0, double.infinity).toDouble(),
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                return LineTooltipItem(
                  '${spot.y.toStringAsFixed(2)} USDT',
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
