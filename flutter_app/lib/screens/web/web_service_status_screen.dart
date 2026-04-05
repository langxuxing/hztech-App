import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';

/// 健康检查与后台同步状态（/api/health + /api/status）
class WebServiceStatusScreen extends StatefulWidget {
  const WebServiceStatusScreen({super.key, this.embedInShell = false});

  final bool embedInShell;

  @override
  State<WebServiceStatusScreen> createState() => _WebServiceStatusScreenState();
}

class _WebServiceStatusScreenState extends State<WebServiceStatusScreen> {
  final _prefs = SecurePrefs();
  bool _loading = true;
  String? _error;
  HealthResponse? _health;
  ServerStatusResponse? _status;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final public = ApiClient(baseUrl, token: null);
      final health = await public.getHealth();
      ServerStatusResponse? st;
      String? stErr;
      if (token != null && token.isNotEmpty) {
        try {
          final authed = ApiClient(baseUrl, token: token);
          st = await authed.getServerStatus();
        } catch (e) {
          stErr = e.toString();
        }
      } else {
        stErr = '未登录，仅展示健康检查';
      }
      if (!mounted) return;
      setState(() {
        _health = health;
        _status = st;
        _error = stErr;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final body = WaterBackground(
      child: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppFinanceStyle.profitGreenEnd),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_error != null && _health == null)
                  Text(
                    _error!,
                    style: TextStyle(color: Colors.red.shade300),
                  ),
                if (_health != null) ...[
                  Text('健康检查', style: AppFinanceStyle.labelTextStyle(context)),
                  const SizedBox(height: 8),
                  FinanceCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _kv('ok', '${_health!.ok}'),
                        _kv('service', _health!.service ?? '—'),
                        _kv(
                          '同步周期(秒)',
                          '${_health!.accountSyncIntervalSec ?? '—'}',
                        ),
                        _kv('static_only', '${_health!.staticOnly}'),
                        if (_health!.processStartedAtUtc != null)
                          _kv('进程启动(UTC)', _health!.processStartedAtUtc!),
                      ],
                    ),
                  ),
                ],
                if (_status != null && _status!.success) ...[
                  const SizedBox(height: 20),
                  Text('运行状态', style: AppFinanceStyle.labelTextStyle(context)),
                  const SizedBox(height: 8),
                  FinanceCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _kv('运行秒数', '${_status!.uptimeSeconds ?? '—'}'),
                        if (_status!.syncDocumentation != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _status!.syncDocumentation!,
                              style: AppFinanceStyle.labelTextStyle(context)
                                  .copyWith(fontSize: 13, height: 1.35),
                            ),
                          ),
                        if (_status!.lastRunCompletedAt != null) ...[
                          const SizedBox(height: 12),
                          _kv('上次同步完成(UTC)', _status!.lastRunCompletedAt!),
                        ],
                        if (_status!.lastLoopError != null &&
                            _status!.lastLoopError!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '周期异常: ${_status!.lastLoopError}',
                              style: TextStyle(
                                color: Colors.orange.shade300,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        Text(
                          '同步步骤',
                          style: AppFinanceStyle.labelTextStyle(context)
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        ..._status!.steps.entries.map((e) {
                          final s = e.value;
                          final ok = s.ok;
                          final icon = ok == true
                              ? Icons.check_circle_outline
                              : ok == false
                                  ? Icons.error_outline
                                  : Icons.help_outline;
                          final color = ok == true
                              ? AppFinanceStyle.profitGreenEnd
                              : ok == false
                                  ? Colors.red.shade300
                                  : AppFinanceStyle.labelColor;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(icon, size: 20, color: color),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        e.key,
                                        style: TextStyle(
                                          color: AppFinanceStyle.valueColor,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      if (s.error != null &&
                                          s.error!.isNotEmpty)
                                        Text(
                                          s.error!,
                                          style: TextStyle(
                                            color: Colors.orange.shade200,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ] else if (_error != null &&
                    _health != null &&
                    _status == null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: AppFinanceStyle.labelTextStyle(context)
                        .copyWith(fontSize: 13),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新检测'),
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.25),
                    foregroundColor: AppFinanceStyle.profitGreenStart,
                  ),
                ),
              ],
            ),
    );

    if (widget.embedInShell) {
      return body;
    }
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '服务状态',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(
                color: AppFinanceStyle.valueColor,
                fontSize: 18,
              ),
        ),
        backgroundColor: AppFinanceStyle.backgroundDark,
        foregroundColor: AppFinanceStyle.valueColor,
        surfaceTintColor: Colors.transparent,
      ),
      body: body,
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              k,
              style: AppFinanceStyle.labelTextStyle(context).copyWith(
                    fontSize: 13,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(
                color: AppFinanceStyle.valueColor,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
