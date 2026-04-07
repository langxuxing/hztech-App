import 'package:flutter/material.dart';

import '../theme/finance_style.dart';

/// 大号加载块：毛玻璃感卡片 + 粗线进度环，供遮罩内与全页等待区复用。
class FinanceInlineLoadingBlock extends StatelessWidget {
  const FinanceInlineLoadingBlock({
    super.key,
    required this.message,
    this.subtitle,
  });

  final String message;
  final String? subtitle;

  static const double _spinnerSize = 88;
  static const double _stroke = 6;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 32),
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          color: AppFinanceStyle.cardBackground,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppFinanceStyle.cardBorder),
          boxShadow: AppFinanceStyle.cardShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _spinnerSize,
              height: _spinnerSize,
              child: CircularProgressIndicator(
                strokeWidth: _stroke,
                color: AppFinanceStyle.textProfit,
                backgroundColor:
                    AppFinanceStyle.valueColor.withValues(alpha: 0.14),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppFinanceStyle.labelTextStyle(context).copyWith(
                color: AppFinanceStyle.valueColor,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  color: AppFinanceStyle.valueColor.withValues(alpha: 0.72),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 账户收益/画像在拉取明细 API 时的半透明遮罩与转圈提示（置于 [Stack] 内，非 [visible] 时占位 [SizedBox.shrink]）。
class AccountDetailLoadingOverlay extends StatelessWidget {
  const AccountDetailLoadingOverlay({
    super.key,
    required this.visible,
    required this.message,
    this.subtitle,
  });

  final bool visible;
  final String message;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Positioned.fill(
      child: AbsorbPointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppFinanceStyle.backgroundDark.withValues(alpha: 0.82),
          ),
          child: Center(
            child: FinanceInlineLoadingBlock(
              message: message,
              subtitle: subtitle ?? '请稍候，数据加载中',
            ),
          ),
        ),
      ),
    );
  }
}
