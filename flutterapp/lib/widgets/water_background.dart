import 'package:flutter/material.dart';

/// 深色底 + 水纹图（最底层之上、内容之下）+ 前景 [child]。
/// 可传入 [baseGradient] 覆盖纯色底（如深蓝灰渐变仪表盘）。
class WaterBackground extends StatelessWidget {
  const WaterBackground({super.key, required this.child, this.baseGradient});

  final Widget child;
  final Gradient? baseGradient;

  static const String _waterAsset = 'images/background-water.png';

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 第 1 层（最底）：纯色/渐变底，避免图片边缘露底
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: baseGradient,
              color: baseGradient == null ? Colors.black : null,
            ),
          ),
        ),
        // 第 2 层：水纹底图，铺满且始终在内容之下
        Positioned.fill(
          child: Image.asset(
            _waterAsset,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
          ),
        ),
        // 第 3 层（最前）：页面内容
        Positioned.fill(child: child),
      ],
    );
  }
}
