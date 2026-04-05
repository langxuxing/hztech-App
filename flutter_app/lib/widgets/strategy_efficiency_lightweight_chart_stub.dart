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
  Widget build(BuildContext context) => const SizedBox.shrink();
}
