import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';

/// Web：资金流收网（仅策略分析师；后端目前为记录桩，可后续对接实盘）。
class WebMoneyflowCatchnetScreen extends StatefulWidget {
  const WebMoneyflowCatchnetScreen({
    super.key,
    this.sharedBots = const [],
    this.embedInShell = false,
  });

  final List<UnifiedTradingBot> sharedBots;
  final bool embedInShell;

  @override
  State<WebMoneyflowCatchnetScreen> createState() => _WebMoneyflowCatchnetScreenState();
}

class _WebMoneyflowCatchnetScreenState extends State<WebMoneyflowCatchnetScreen> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _bots = [];
  String? _selectedBotId;
  bool _loading = false;
  String? _lastMessage;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bots = List<UnifiedTradingBot>.from(widget.sharedBots);
    if (_bots.isEmpty) {
      _loadBots();
    } else {
      _pickDefaultBot();
    }
  }

  @override
  void didUpdateWidget(WebMoneyflowCatchnetScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sharedBots != oldWidget.sharedBots &&
        widget.sharedBots.isNotEmpty) {
      _bots = List<UnifiedTradingBot>.from(widget.sharedBots);
      _pickDefaultBot();
    }
  }

  void _pickDefaultBot() {
    if (_selectedBotId != null &&
        _bots.any((b) => b.tradingbotId == _selectedBotId)) {
      return;
    }
    _selectedBotId =
        _bots.isNotEmpty ? _bots.first.tradingbotId : null;
  }

  Future<void> _loadBots() async {
    try {
      final base = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(base, token: token);
      final resp = await api.getTradingBots();
      if (!mounted) return;
      setState(() {
        _bots = resp.botList;
        _pickDefaultBot();
      });
    } catch (_) {}
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
      _lastMessage = null;
    });
    try {
      final base = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(base, token: token);
      final msg = await api.postStrategyAnalystAutoNetTest(
        botId: _selectedBotId,
      );
      if (!mounted) return;
      setState(() {
        _lastMessage = msg;
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
  Widget build(BuildContext context) {
    final body = WaterBackground(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '「收网测试」仅调用后端测试接口并写入日志，不会真实平仓或撤单。',
              style: AppFinanceStyle.labelTextStyle(context).copyWith(
                    fontSize: 14,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 20),
            Text(
              '交易账户（可选）',
              style: AppFinanceStyle.labelTextStyle(context),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppFinanceStyle.cardBorder),
              ),
              child: DropdownButton<String?>(
                value: _selectedBotId,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                dropdownColor: const Color(0xFF2a2a36),
                style: const TextStyle(color: AppFinanceStyle.valueColor),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('不指定账户'),
                  ),
                  for (final b in _bots)
                    if (b.tradingbotId.isNotEmpty)
                      DropdownMenuItem<String?>(
                        value: b.tradingbotId,
                        child: Text(
                          b.tradingbotId,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                ],
                onChanged: (v) => setState(() => _selectedBotId = v),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loading ? null : _submit,
              icon: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.science_outlined),
              label: Text(_loading ? '请求中…' : '发送测试请求'),
            ),
            if (_lastMessage != null) ...[
              const SizedBox(height: 20),
              SelectableText(
                _lastMessage!,
                style: const TextStyle(
                  color: AppFinanceStyle.profitGreenEnd,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 20),
              SelectableText(
                _error!,
                style: TextStyle(
                  color: AppFinanceStyle.textLoss,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    );

    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: widget.embedInShell
          ? null
          : AppBar(
              title: Text(
                '自动收网（测试）',
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
}
