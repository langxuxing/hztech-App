import 'package:flutter/material.dart';

import '../secure/prefs.dart';

/// 全屏洛伦兹吸引子图（后端 `GET /res/bg`），无渐变蒙版。
class LorenzResBgBackground extends StatefulWidget {
  const LorenzResBgBackground({super.key});

  @override
  State<LorenzResBgBackground> createState() => _LorenzResBgBackgroundState();
}

class _LorenzResBgBackgroundState extends State<LorenzResBgBackground> {
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
    return SizedBox.expand(
      child: _bgUrl != null
          ? Image.network(
              _bgUrl!,
              key: ValueKey<int>(_imgKey),
              fit: BoxFit.cover,
              alignment: Alignment.center,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFF0a1628)),
            )
          : const ColoredBox(color: Color(0xFF0a1628)),
    );
  }
}
