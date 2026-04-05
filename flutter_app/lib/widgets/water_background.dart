import 'package:flutter/material.dart';

/// 水纹背景：默认黑色底色，背景图填满整个窗口，透明度 50%。
/// 可传入 [baseGradient] 覆盖纯色底（如深蓝灰渐变仪表盘）。
class WaterBackground extends StatelessWidget {
  const WaterBackground({super.key, required this.child, this.baseGradient});

  final Widget child;
  final Gradient? baseGradient;

  static const String _assetPath = 'images/background-water.png';
  static const double _opacity = 0.5;

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
        // 背景图填满整个窗口
        Opacity(
          opacity: _opacity,
          child: Image.asset(
            _assetPath,
            fit: BoxFit.cover,
          ),
        ),
        child,
      ],
    );
  }
}
