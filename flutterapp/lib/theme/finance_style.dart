import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
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

  /// 全局正文/标签缺省文字色 RGB(247,247,247)
  static const Color textDefault = Color(0xFFF7F7F7);

  /// 盈利/多/正向文案与图表正色 RGB(2,125,32)
  static const Color textProfit = Color(0xFF027D20);

  /// 亏损/空/负向文案与图表负色 RGB(188,74,101)
  static const Color textLoss = Color(0xFFBC4A65);

  /// 标签/副标题（与缺省正文统一）
  static const Color labelColor = textDefault;

  /// 主数值色（与缺省正文统一）
  static const Color valueColor = textDefault;

  /// ShaderMask 渐变用盈利色（两端同色，保持 API 兼容）
  static const Color profitGreenStart = textProfit;
  static const Color profitGreenEnd = textProfit;

  /// 图表柱/折线与文案盈亏色一致
  static const Color chartProfit = textProfit;
  static const Color chartLoss = textLoss;

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

  /// Web 顶部汇总条（账户总览 / 运行概览）统一内边距与间距；约为原竖直方向的 2 倍。
  static const EdgeInsets webSummaryStripPadding = EdgeInsets.symmetric(
    horizontal: 20,
    vertical: 32,
  );

  /// 标题与汇总 [FinanceCard] 之间的间距。
  static const double webSummaryTitleSpacing = 32;

  /// 汇总条内窄屏多行行距。
  static const double webSummaryNarrowGap = 24;

  /// 汇总条内宽屏列间距。
  static const double webSummaryWideGap = 32;

  /// Web 宽表/对比表网格线（与毛玻璃卡协调，避免生硬纯灰线）。
  static const Color webDataGridLine = Color.fromRGBO(255, 255, 255, 0.08);

  /// Web 数据表左侧指标列背景。
  static const Color webDataTableLabelBg = Color.fromRGBO(255, 255, 255, 0.035);

  /// Web 数据表数据区背景。
  static const Color webDataTableCellBg = Color.fromRGBO(0, 0, 0, 0.2);

  /// Web 数据表行 hover（略亮于 [webDataTableCellBg]）。
  static const Color webDataTableRowHoverBg = Color.fromRGBO(
    255,
    255,
    255,
    0.04,
  );

  /// Web 子页 Tab 条外框（赛季 Hub、策略能效卡片内等与侧栏页一致）。
  static BoxDecoration webSubtleInsetPanelDecoration() => BoxDecoration(
    color: Colors.white.withValues(alpha: 0.04),
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: cardBorder),
  );

  /// 汇总条主数值字号（与条高度配套；相对上一版 48 再 +50% → 72）。
  static const double webSummaryValueFontSize = 72;

  /// 移动端列表页「账户概览」等顶部汇总卡内边距（略紧于 [webSummaryStripPadding]）。
  static const EdgeInsets mobileSummaryStripPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 24,
  );

  /// 移动端顶部汇总主数值字号：随逻辑宽度缩放，避免超窄屏爆版、大屏仍显「大气」。
  static double mobileSummaryValueFontSize(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return (w * 0.075).clamp(24.0, 48.0);
  }

  /// 移动端表头汇总单行：小标签在左、大号数值在右（与账户总览顶部条横向布局一致）。
  /// 置于 [Row] 的 [Expanded] 子节点内，以便长数字省略。
  static Widget mobileSummaryInlinePair(
    BuildContext context, {
    required String label,
    required String value,
    required Color valueColor,
    MainAxisAlignment rowAlign = MainAxisAlignment.start,
  }) {
    final labelStyle =
        (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: labelColor,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        );
    final vs = valueTextStyle(
      context,
      fontSize: mobileSummaryValueFontSize(context),
    ).copyWith(color: valueColor);
    final end = rowAlign == MainAxisAlignment.end;
    return Row(
      mainAxisAlignment: rowAlign,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: labelStyle),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            style: vs,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: end ? TextAlign.right : TextAlign.left,
          ),
        ),
      ],
    );
  }

  /// 移动端表头汇总单列：标签在上、主数值在下，列内水平居中（三列 [Row]+[Expanded] 时与各列等宽对齐）。
  static Widget mobileSummaryStackCell(
    BuildContext context, {
    required String label,
    required String value,
    required Color valueColor,
  }) {
    final labelStyle =
        (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: labelColor,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        );
    final vs = valueTextStyle(
      context,
      fontSize: mobileSummaryValueFontSize(context),
    ).copyWith(color: valueColor);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: labelStyle, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          value,
          style: vs,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// 运行概览汇总卡与下方批量操作按钮的间距（约为原 12 的 2 倍）。
  static const double webSummaryCardToBulkActionsGap = 24;

  /// 毛玻璃模糊 sigma
  static const double cardBlurSigma = 14;

  /// Web 部分页面次级下拉（赛季/历史等）用略小字号，避免喧宾夺主。
  static const double webAccountProfitBotDropdownFontSize = 16;


  /// 与「账户概览」列表标题、账户收益/画像章节 [_sectionTitle] 同级：**App** `titleLarge`+2，**Web** +4。
  /// 用于账户选择 [DropdownButton]，避免因单独写死 14–16px 而比卡片标题明显更小（并非控件高度限制）。
  static TextStyle accountProfitOverviewHeadingStyle(BuildContext context) {
    final tl = Theme.of(context).textTheme.titleLarge;
    final bump = kIsWeb ? 4 : 2;
    return (tl ?? const TextStyle()).copyWith(
      color: labelColor,
      fontSize: (tl?.fontSize ?? 22) + bump,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.35,
    );
  }

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
