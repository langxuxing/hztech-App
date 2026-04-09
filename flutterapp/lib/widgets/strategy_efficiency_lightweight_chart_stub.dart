import 'package:flutter/material.dart';

import '../api/models.dart';

/// 非 Web 平台占位（策略能效图表仅在 Web 使用 Lightweight Charts）。
class StrategyEfficiencyLightweightChart extends StatelessWidget {
  const StrategyEfficiencyLightweightChart({
    super.key,
    required this.rows,
    this.height = 420,
  });

  final List<StrategyDailyEfficiencyRow> rows;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            rows.isEmpty
                ? '暂无策略能效日线数据。'
                : '策略能效组合图仅在 Web 端展示；请在浏览器中打开本页。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
