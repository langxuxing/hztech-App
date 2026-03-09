import 'package:flutter/material.dart';

/// 水纹背景：黑色底色，背景图填满整个窗口，透明度 50%。
class WaterBackground extends StatelessWidget {
  const WaterBackground({super.key, required this.child});

  final Widget child;

  static const String _assetPath = 'images/background-water.png';
  static const double _opacity = 0.5;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 统一黑色底色
        Container(color: Colors.black),
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
