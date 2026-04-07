import 'package:flutter/material.dart';

import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';

/// QTrader Campaign / 活动域为二期规划，此处为路线图说明。
class WebCampaignRoadmapScreen extends StatelessWidget {
  const WebCampaignRoadmapScreen({super.key, this.embedInShell = false});

  final bool embedInShell;

  @override
  Widget build(BuildContext context) {
    final body = WaterBackground(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            '活动与 Campaign（二期）',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  color: AppFinanceStyle.valueColor,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 16),
          Text(
            '当前应用已支持按交易账户的「赛季」记录与启停（见「赛季」页与策略启停）。'
            'QTrader-web 中的 Campaign 列表、活动赛季联动、盈利归因与 mark-positions 等能力依赖 QTrader 核心库与独立数据模型，'
            '计划在后续迭代中通过 API 代理或数据同步接入。',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  fontSize: 14,
                  height: 1.45,
                ),
          ),
          const SizedBox(height: 20),
          Text(
            '一期已完成',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppFinanceStyle.valueColor,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '· 赛季列表与进行中状态展示\n'
            '· 与现有 season-start / season-stop 脚本联动说明',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  fontSize: 14,
                  height: 1.45,
                ),
          ),
        ],
      ),
    );

    if (embedInShell) {
      return body;
    }
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '活动路线图',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(
                color: AppFinanceStyle.valueColor,
                fontSize: 18,
              ),
        ),
        backgroundColor: AppFinanceStyle.backgroundDark,
        foregroundColor: AppFinanceStyle.valueColor,
        surfaceTintColor: Colors.transparent,
      ),
      body: body,
    );
  }
}
