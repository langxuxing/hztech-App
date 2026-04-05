import 'package:flutter/material.dart';

import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';

/// 洛伦兹吸引子主视觉（后端 `GET /res/bg`）。
class WebHomeScreen extends StatefulWidget {
  const WebHomeScreen({super.key});

  @override
  State<WebHomeScreen> createState() => _WebHomeScreenState();
}

class _WebHomeScreenState extends State<WebHomeScreen> {
  final _prefs = SecurePrefs();
  String? _bgUrl;
  int _imgKey = 0;

  @override
  void initState() {
    super.initState();
    _resolveUrl();
  }

  Future<void> _resolveUrl() async {
    final base = await _prefs.backendBaseUrl;
    if (!mounted) return;
    final b = base.trim();
    if (b.isEmpty) {
      setState(() => _bgUrl = null);
      return;
    }
    final u = b.startsWith('http') ? b : 'http://$b';
    final normalized = u.endsWith('/') ? u : '$u/';
    setState(() {
      _bgUrl = '${normalized}res/bg';
      _imgKey++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_bgUrl != null)
            Image.network(
              _bgUrl!,
              key: ValueKey<int>(_imgKey),
              fit: BoxFit.cover,
              alignment: Alignment.center,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFF0a1628)),
            )
          else
            const ColoredBox(color: Color(0xFF0a1628)),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.35),
                  Colors.black.withValues(alpha: 0.75),
                ],
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
                                color: AppFinanceStyle.valueColor,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
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
