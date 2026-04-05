import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../utils/number_display_format.dart';
import '../../widgets/water_background.dart';

/// 按账户展示赛季列表（与策略启停赛季操作联动）
class WebSeasonsScreen extends StatefulWidget {
  const WebSeasonsScreen({
    super.key,
    this.sharedBots = const [],
    this.embedInShell = false,
    this.accountIdFromParent,
  });

  final List<UnifiedTradingBot> sharedBots;
  final bool embedInShell;

  /// 非空时由上层（如赛季/历史仓位 Hub）统一选账户，本页不显示账户下拉。
  final String? accountIdFromParent;

  @override
  State<WebSeasonsScreen> createState() => _WebSeasonsScreenState();
}

class _WebSeasonsScreenState extends State<WebSeasonsScreen> {
  final _prefs = SecurePrefs();
  String? _botId;
  List<BotSeason> _seasons = [];
  int? _activeCount;
  bool _loading = false;
  String? _error;

  List<UnifiedTradingBot> get _bots => widget.sharedBots;

  String? get _effectiveBotId =>
      widget.accountIdFromParent ?? _botId;

  Future<void> _load() async {
    final bid = _effectiveBotId;
    if (bid == null || bid.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.getTradingbotSeasons(bid, limit: 80);
      if (!mounted) return;
      if (!resp.success) {
        setState(() {
          _error = '加载失败';
          _loading = false;
        });
        return;
      }
      setState(() {
        _seasons = resp.seasons;
        _activeCount = resp.activeSeasonCount;
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
    if (_bots.isNotEmpty) {
      _botId = widget.accountIdFromParent ?? _bots.first.tradingbotId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void didUpdateWidget(WebSeasonsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.accountIdFromParent != null &&
        widget.accountIdFromParent != oldWidget.accountIdFromParent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = WaterBackground(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.accountIdFromParent == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: DropdownButtonFormField<String>(
                value: _botId != null &&
                        _bots.any((b) => b.tradingbotId == _botId)
                    ? _botId
                    : null,
                decoration: InputDecoration(
                  labelText: '账户',
                  labelStyle: AppFinanceStyle.labelTextStyle(context),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.06),
                ),
                dropdownColor: const Color(0xFF1a1a24),
                style: TextStyle(color: AppFinanceStyle.valueColor),
                items: _bots
                    .map(
                      (b) => DropdownMenuItem(
                        value: b.tradingbotId,
                        child: Text(
                          (b.tradingbotName != null &&
                                  b.tradingbotName!.isNotEmpty)
                              ? b.tradingbotName!
                              : b.tradingbotId,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  setState(() => _botId = v);
                  _load();
                },
              ),
            )
          else
            const SizedBox(height: 8),
          if (_activeCount != null && _activeCount! > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '进行中赛季数：$_activeCount（请在「策略启停」使用赛季开始/停止）',
                style: AppFinanceStyle.labelTextStyle(context).copyWith(
                      fontSize: 13,
                      color: AppFinanceStyle.profitGreenEnd,
                    ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Colors.red.shade300, fontSize: 13),
              ),
            ),
          Expanded(
            child: _bots.isEmpty
                ? Center(
                    child: Text(
                      '暂无账户列表',
                      style: AppFinanceStyle.labelTextStyle(context),
                    ),
                  )
                : _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppFinanceStyle.profitGreenEnd,
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _seasons.length,
                        itemBuilder: (ctx, i) {
                          final s = _seasons[i];
                          final active = s.isActive == true;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: FinanceCard(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (active)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppFinanceStyle.profitGreenEnd
                                              .withValues(alpha: 0.2),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          '进行中',
                                          style: TextStyle(
                                            color:
                                                AppFinanceStyle.profitGreenEnd,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      )
                                    else
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white12,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          '已结束',
                                          style: TextStyle(
                                            color: AppFinanceStyle.labelColor,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    const Spacer(),
                                    Text(
                                      '#${s.id}',
                                      style: AppFinanceStyle.labelTextStyle(
                                        context,
                                      ).copyWith(fontSize: 12),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                _line(
                                  context,
                                  '开始',
                                  s.startedAt ?? '—',
                                ),
                                _line(
                                  context,
                                  '结束',
                                  s.stoppedAt ?? '—',
                                ),
                                if (s.durationSeconds != null)
                                  _line(
                                    context,
                                    '时长(秒)',
                                    '${s.durationSeconds}',
                                  ),
                                _line(
                                  context,
                                  '初期',
                                  formatUiInteger(s.initialBalance),
                                ),
                                if (s.finalBalance != null)
                                  _line(
                                    context,
                                    '期末',
                                    formatUiInteger(s.finalBalance!),
                                  ),
                                if (s.profitAmount != null)
                                  _line(
                                    context,
                                    '盈利',
                                    s.profitAmount!.toStringAsFixed(1),
                                  ),
                                if (s.profitPercent != null)
                                  _line(
                                    context,
                                    '收益率',
                                    formatUiPercentLabel(s.profitPercent!),
                                  ),
                              ],
                            ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );

    if (widget.embedInShell) {
      return content;
    }
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '赛季',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(
                color: AppFinanceStyle.valueColor,
                fontSize: 18,
              ),
        ),
        backgroundColor: AppFinanceStyle.backgroundDark,
        foregroundColor: AppFinanceStyle.valueColor,
        surfaceTintColor: Colors.transparent,
      ),
      body: content,
    );
  }

  Widget _line(BuildContext context, String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
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
