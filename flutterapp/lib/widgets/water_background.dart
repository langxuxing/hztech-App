import 'package:flutter/material.dart';

/// 深色底 + 前景 [child]（水纹背景图已暂时关闭，便于 Web 调试与减负渲染）。
/// 可传入 [baseGradient] 覆盖纯色底（如深蓝灰渐变仪表盘）。
class WaterBackground extends StatelessWidget {
  const WaterBackground({super.key, required this.child, this.baseGradient});

  final Widget child;
  final Gradient? baseGradient;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: baseGradient,
              color: baseGradient == null ? Colors.black : null,
            ),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}
