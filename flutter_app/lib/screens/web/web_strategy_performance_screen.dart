import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';

/// Web：策略日线能效评估（OKX True Range 与账户现金日变动比值），按交易账户切换。
class WebStrategyPerformanceScreen extends StatefulWidget {
  const WebStrategyPerformanceScreen({super.key, this.sharedBots = const []});

  final List<UnifiedTradingBot> sharedBots;

  @override
  State<WebStrategyPerformanceScreen> createState() =>
      _WebStrategyPerformanceScreenState();
}

class _WebStrategyPerformanceScreenState
    extends State<WebStrategyPerformanceScreen> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _bots = [];
  String? _selectedId;
  StrategyDailyEfficiencyResponse? _efficiency;
  bool _loading = true;
  String? _loadError;

  Future<void> _loadBots() async {
    if (widget.sharedBots.isNotEmpty) {
      setState(() {
        _bots = List.from(widget.sharedBots);
        _selectedId ??= _bots.first.tradingbotId;
      });
      return;
    }
    final baseUrl = await _prefs.backendBaseUrl;
    final token = await _prefs.authToken;
    final api = ApiClient(baseUrl, token: token);
    final resp = await api.getTradingBots();
    if (!mounted) return;
    setState(() {
      _bots = resp.botList;
      if (_selectedId == null && _bots.isNotEmpty) {
        _selectedId = _bots.first.tradingbotId;
      }
    });
  }

  Future<void> _loadEfficiency() async {
    final botId = _selectedId;
    if (botId == null || botId.isEmpty) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final effResp = await api.getStrategyDailyEfficiency(botId);
      if (!mounted) return;
      setState(() {
        _efficiency = effResp;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _efficiency = null;
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadBots();
    if (!mounted) return;
    if (_bots.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    await _loadEfficiency();
  }

  String _fmtOpt(double? v, {int digits = 2}) {
    if (v == null || !v.isFinite) return '—';
    return v.toStringAsFixed(digits);
  }

  Widget _buildEfficiencySection(BuildContext context) {
    if (_loadError != null) {
      return FinanceCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '策略能效评估',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppFinanceStyle.labelColor,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _loadError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
      );
    }
    final eff = _efficiency;
    if (eff == null) {
      return const SizedBox.shrink();
    }
    if (!eff.success) {
      return FinanceCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '策略能效评估',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppFinanceStyle.labelColor,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              eff.message ?? '市场数据不可用（请检查网络或交易对代码）',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
      );
    }
    final rows = eff.rows.take(90).toList();
    final cashNote = eff.cashBasis == 'account_snapshots_cash'
        ? '现金变动来自 account_snapshots（availEq），按 UTC 自然日汇总。'
        : '非 Account_List 账户无现金快照列；仍显示 OKX 日线 TR。';
    return FinanceCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '策略能效评估',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppFinanceStyle.labelColor,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            '${eff.instId} 日线 True Range（OKX 公开 K 线）；比值 = 现金日变动% ÷ TR 占收盘价%。$cashNote',
            style: AppFinanceStyle.labelTextStyle(
              context,
            ).copyWith(fontSize: 12),
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 40,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 48,
              columns: const [
                DataColumn(label: Text('日期(UTC)')),
                DataColumn(label: Text('TR'), numeric: true),
                DataColumn(label: Text('TR%'), numeric: true),
                DataColumn(label: Text('现金Δ USDT'), numeric: true),
                DataColumn(label: Text('现金Δ%'), numeric: true),
                DataColumn(label: Text('比值'), numeric: true),
              ],
              rows: [
                for (final e in rows)
                  DataRow(
                    cells: [
                      DataCell(Text(e.day)),
                      DataCell(Text(_fmtOpt(e.tr, digits: 6))),
                      DataCell(Text(_fmtOpt(e.trPct))),
                      DataCell(
                        Text(
                          _fmtOpt(e.cashDeltaUsdt),
                          style: TextStyle(
                            color: (e.cashDeltaUsdt ?? 0) >= 0
                                ? AppFinanceStyle.profitGreenEnd
                                : Colors.red,
                          ),
                        ),
                      ),
                      DataCell(Text(_fmtOpt(e.cashDeltaPct))),
                      DataCell(Text(_fmtOpt(e.efficiencyRatio))),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: RefreshIndicator(
          onRefresh: () async {
            await _loadBots();
            await _loadEfficiency();
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                sliver: SliverToBoxAdapter(
                  child: FinanceCard(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '选择账户',
                            style: AppFinanceStyle.labelTextStyle(context),
                          ),
                        ),
                        if (_bots.isNotEmpty)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 360),
                            child: DropdownButtonFormField<String>(
                              key: ValueKey(_selectedId),
                              initialValue:
                                  _selectedId ?? _bots.first.tradingbotId,
                              isExpanded: true,
                              dropdownColor: AppFinanceStyle.cardBackground,
                              style: const TextStyle(
                                color: AppFinanceStyle.valueColor,
                              ),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: 0.06),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              items: _bots
                                  .map(
                                    (b) => DropdownMenuItem<String>(
                                      value: b.tradingbotId,
                                      child: Text(
                                        b.tradingbotName ?? b.tradingbotId,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) async {
                                if (v == null) return;
                                setState(() => _selectedId = v);
                                await _loadEfficiency();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_loading)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_bots.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Text(
                      '暂无交易账户',
                      style: AppFinanceStyle.labelTextStyle(context),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
                  sliver: SliverToBoxAdapter(
                    child: _buildEfficiencySection(context),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
