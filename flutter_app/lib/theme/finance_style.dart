import 'dart:ui';

import 'package:flutter/material.dart';

/// 与 aa.html 一致的金融卡片风格：深色背景、毛玻璃卡片、标签/数值/盈利色。
class AppFinanceStyle {
  AppFinanceStyle._();

  /// 页面背景深色 #0a0a0f
  static const Color backgroundDark = Color(0xFF0a0a0f);

  /// 卡片背景 rgba(20, 20, 25, 0.65)
  static const Color cardBackground = Color.fromRGBO(20, 20, 25, 0.65);

  /// 卡片边框 rgba(255,255,255,0.06)
  static const Color cardBorder = Color.fromRGBO(255, 255, 255, 0.06);

  /// 卡片内顶部高光
  static const Color cardHighlight = Color.fromRGBO(255, 255, 255, 0.2);

  /// 标签/副标题色 #A0A0B0
  static const Color labelColor = Color(0xFFA0A0B0);

  /// 主数值色 #E8E8F0
  static const Color valueColor = Color(0xFFE8E8F0);

  /// 盈利绿渐变起点 #A8FF78
  static const Color profitGreenStart = Color(0xFFA8FF78);

  /// 盈利绿渐变终点 #7EC850
  static const Color profitGreenEnd = Color(0xFF7EC850);

  /// 图表（柱/折线/日历盈亏强调）：盈利 RGB(51, 118, 41)
  static const Color chartProfit = Color(0xFF337629);

  /// 图表（柱/折线/日历盈亏强调）：亏损 RGB(79, 38, 44)
  static const Color chartLoss = Color(0xFF4F262C);

  /// 外阴影
  static const List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.4),
      blurRadius: 32,
      offset: Offset(0, 8),
    ),
    BoxShadow(
      color: Color.fromRGBO(255, 255, 255, 0.08),
      blurRadius: 0,
      offset: Offset(0, 1),
      spreadRadius: 0,
    ),
  ];

  /// 卡片圆角 18
  static const double cardRadius = 18;

  /// 毛玻璃模糊 sigma
  static const double cardBlurSigma = 14;

  /// 标签字体 14px, font-weight 500
  static TextStyle labelTextStyle(BuildContext context) {
    return (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
        .copyWith(fontSize: 14, fontWeight: FontWeight.w500, color: labelColor);
  }

  /// 主数值字体：大号、粗体、valueColor
  static TextStyle valueTextStyle(BuildContext context, {double? fontSize}) {
    return (Theme.of(context).textTheme.headlineSmall ?? const TextStyle())
        .copyWith(
          fontSize: fontSize ?? 32,
          fontWeight: FontWeight.w800,
          color: valueColor,
          letterSpacing: -0.5,
        );
  }

  /// 盈利文字渐变色（用 LinearGradient 时需 ShaderMask）
  static LinearGradient get profitGradient => const LinearGradient(
    colors: [profitGreenStart, profitGreenEnd],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

/// 与 aa.html 一致的金融毛玻璃卡片：半透明、模糊、细边框、顶高光线、阴影。
class FinanceCard extends StatelessWidget {
  const FinanceCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,

    /// 状态强调色：加粗边框、顶部色条与可选外发光（策略启停等仪表盘卡片）。
    this.statusAccent,

    /// 与 [statusAccent] 配合，0–1 调节外发光强度（如运行中呼吸灯）。
    this.accentGlowT = 0,

    /// 若提供则替代纯色卡面，形成深灰微渐变（与毛玻璃叠加）。
    this.surfaceGradient,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color? statusAccent;

  /// 0–1，默认 0。
  final double accentGlowT;
  final Gradient? surfaceGradient;

  @override
  Widget build(BuildContext context) {
    final accent = statusAccent;
    final borderColor = accent != null
        ? Color.alphaBlend(
            accent.withValues(alpha: 0.42),
            AppFinanceStyle.cardBorder,
          )
        : AppFinanceStyle.cardBorder;
    final glowT = accentGlowT.clamp(0.0, 1.0);
    final extraShadow = accent != null
        ? <BoxShadow>[
            BoxShadow(
              color: accent.withValues(alpha: 0.08 + 0.22 * glowT),
              blurRadius: 12 + 14 * glowT,
              spreadRadius: 0,
              offset: const Offset(0, 2),
            ),
          ]
        : const <BoxShadow>[];

    final content = ClipRRect(
      borderRadius: BorderRadius.circular(AppFinanceStyle.cardRadius),
      child: Stack(
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: AppFinanceStyle.cardBlurSigma,
                sigmaY: AppFinanceStyle.cardBlurSigma,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: surfaceGradient == null
                  ? AppFinanceStyle.cardBackground
                  : null,
              gradient: surfaceGradient,
              borderRadius: BorderRadius.circular(AppFinanceStyle.cardRadius),
              border: Border.all(
                color: borderColor,
                width: accent != null ? 1.5 : 1,
              ),
              boxShadow: [...AppFinanceStyle.cardShadow, ...extraShadow],
            ),
            child: Stack(
              children: [
                if (accent != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            accent.withValues(alpha: 0.35 + 0.45 * glowT),
                            accent.withValues(alpha: 0.15 + 0.2 * glowT),
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.35 * glowT),
                            blurRadius: 10,
                            spreadRadius: -1,
                          ),
                        ],
                      ),
                    ),
                  ),
                // 顶部高光线（与状态条并存时略下移）
                Positioned(
                  left: 0,
                  right: 0,
                  top: accent != null ? 4 : 0,
                  height: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          AppFinanceStyle.cardHighlight.withValues(alpha: 0.5),
                          Colors.transparent,
                        ],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: padding ?? const EdgeInsets.all(24),
                  child: child,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppFinanceStyle.cardRadius),
          child: content,
        ),
      );
    }
    return content;
  }
}
