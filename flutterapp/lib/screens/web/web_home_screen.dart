import 'package:flutter/material.dart';

import '../../theme/finance_style.dart';

/// Web 首页：本地洛伦兹吸引子图作为全屏背景。
class WebHomeScreen extends StatelessWidget {
  const WebHomeScreen({super.key});

  static const String _bgAsset = 'images/lorenz_butterfly.jpg';

  /// 与 [images/lorenz_butterfly.jpg] 像素尺寸一致，用于按比例缩放，避免 cover 裁切。
  static const double _imageWidthPx = 1000;
  static const double _imageHeightPx = 800;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.center,
              child: SizedBox(
                width: _imageWidthPx,
                height: _imageHeightPx,
                child: Image.asset(
                  _bgAsset,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(height: 12),
                        Text(
                          '知空守拙，细水长流\n顺势扬帆，乘风破浪',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: AppFinanceStyle.textDefault,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
