import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../constants/poll_intervals.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';

/// 轮询后端健康状态：异常时使用全屏模态遮罩阻止页面交互。
class BackendHealthGuard extends StatefulWidget {
  const BackendHealthGuard({
    super.key,
    required this.child,
    this.pollInterval = PollIntervals.shortPoll,
    this.requestTimeout = const Duration(seconds: 3),
  });

  final Widget child;
  final Duration pollInterval;
  final Duration requestTimeout;

  @override
  State<BackendHealthGuard> createState() => _BackendHealthGuardState();
}

class _BackendHealthGuardState extends State<BackendHealthGuard>
    with SingleTickerProviderStateMixin {
  final _prefs = SecurePrefs();
  Timer? _timer;
  bool _isChecking = false;
  bool _degraded = false;
  String _message = '正在检查网络与服务状态...';
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _runHealthCheck();
    _timer = Timer.periodic(widget.pollInterval, (_) => _runHealthCheck());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _runHealthCheck() async {
    if (_isChecking) return;
    _isChecking = true;
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final publicApi = ApiClient(baseUrl, token: null);
      final health =
          await publicApi.getHealth().timeout(widget.requestTimeout);
      if (!mounted) return;
      setState(() {
        _degraded = !health.ok;
        _message = health.ok ? '' : '服务连接不稳定，正在自动重试...';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _degraded = true;
        _message = '网络信号较弱或服务不可达，请稍候...';
      });
    } finally {
      _isChecking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_degraded) ...[
          const ModalBarrier(
            dismissible: false,
            color: Color(0xB3000000),
          ),
          Center(
            child: Container(
              width: 340,
              constraints: const BoxConstraints(maxWidth: 380),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                color: const Color(0xFF101317),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppFinanceStyle.textDefault.withValues(alpha: 0.25),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 18,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FadeTransition(
                    opacity: _pulse.drive(
                      Tween<double>(begin: 0.45, end: 1),
                    ),
                    child: ScaleTransition(
                      scale: _pulse.drive(
                        Tween<double>(begin: 0.92, end: 1.08),
                      ),
                      child: const Icon(
                        Icons.wifi_off_rounded,
                        size: 44,
                        color: AppFinanceStyle.textLoss,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '连接异常',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppFinanceStyle.textDefault,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppFinanceStyle.textDefault.withValues(alpha: 0.88),
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
