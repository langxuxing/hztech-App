import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../auth/app_user_role.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';

/// 已入库的历史平仓（GET /api/tradingbots/{id}/position-history）
class WebPositionHistoryScreen extends StatefulWidget {
  const WebPositionHistoryScreen({
    super.key,
    this.sharedBots = const [],
    this.embedInShell = false,
    this.appUserRole,
  });

  final List<UnifiedTradingBot> sharedBots;
  final bool embedInShell;
  final AppUserRole? appUserRole;

  @override
  State<WebPositionHistoryScreen> createState() =>
      _WebPositionHistoryScreenState();
}

class _WebPositionHistoryScreenState extends State<WebPositionHistoryScreen> {
  final _prefs = SecurePrefs();
  String? _botId;
  List<PositionHistoryRow> _rows = [];
  int? _nextBefore;
  bool _loading = false;
  String? _error;
  bool _syncing = false;

  bool get _isAdmin => widget.appUserRole == AppUserRole.admin;

  List<UnifiedTradingBot> get _bots => widget.sharedBots;

  static const Color _tableHeaderFg = Color(0xFFF2F2F8);
  static const Color _tableCellFg = Color(0xFFE8E8F0);
  static const Color _tableBorder = Color(0x44FFFFFF);

  TextStyle get _headerStyle => const TextStyle(
        color: _tableHeaderFg,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      );

  TextStyle get _cellStyle => const TextStyle(
        color: _tableCellFg,
        fontSize: 13,
        height: 1.25,
      );

  String _formatUtcMs(String? ms) {
    if (ms == null || ms.isEmpty) return '—';
    final v = int.tryParse(ms);
    if (v == null) return ms;
    final dt = DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)} UTC';
  }

  String _mgnLabel(String? m) {
    final s = (m ?? '').toLowerCase();
    if (s == 'cross') return '全仓';
    if (s == 'isolated') return '逐仓';
    return m ?? '—';
  }

  Widget _headerCell(String text) => Text(text, style: _headerStyle);

  Widget _cell(String? text, {Color? color}) {
    return Text(
      text == null || text.isEmpty ? '—' : text,
      style: color != null ? _cellStyle.copyWith(color: color) : _cellStyle,
    );
  }

  Color? _pnlColor(String? pnlText) {
    if (pnlText == null || pnlText.isEmpty) return null;
    final v = double.tryParse(pnlText);
    if (v == null) return null;
    if (v > 0) return AppFinanceStyle.profitGreenEnd;
    if (v < 0) return const Color(0xFFFF6B6B);
    return null;
  }

  Widget _sideCell(String? side) {
    final s = (side ?? '').toLowerCase();
    Color fg;
    Color bg;
    String label;
    if (s == 'long') {
      label = '多 long';
      fg = const Color(0xFF7EE787);
      bg = const Color(0xFF1A3D24);
    } else if (s == 'short') {
      label = '空 short';
      fg = const Color(0xFFFF8A8A);
      bg = const Color(0xFF3D1A1A);
    } else {
      label = side ?? '—';
      fg = _tableCellFg;
      bg = Colors.white12;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withValues(alpha: 0.45)),
      ),
      child: Text(label, style: _cellStyle.copyWith(color: fg, fontSize: 12)),
    );
  }

  Future<void> _load({bool append = false}) async {
    final bid = _botId;
    if (bid == null || bid.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      if (!append) _rows = [];
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.getPositionHistory(
        bid,
        limit: 80,
        beforeUtime: append ? _nextBefore : null,
      );
      if (!mounted) return;
      if (!resp.success) {
        setState(() {
          _error = '加载失败';
          _loading = false;
        });
        return;
      }
      setState(() {
        if (append) {
          _rows = [..._rows, ...resp.rows];
        } else {
          _rows = resp.rows;
        }
        _nextBefore = resp.nextBeforeUtime;
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

  Future<void> _syncNow() async {
    final bid = _botId;
    if (bid == null || !_isAdmin) return;
    setState(() => _syncing = true);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final r = await api.syncPositionHistory(bid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(r.message ?? (r.success ? 'ok' : '失败'))),
      );
      if (r.success) await _load(append: false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (_bots.isNotEmpty) {
      _botId = _bots.first.tradingbotId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = WaterBackground(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
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
                ),
                if (_isAdmin) ...[
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _syncing ? null : _syncNow,
                    icon: _syncing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_download_outlined),
                    tooltip: '从 OKX 同步历史仓位',
                  ),
                ],
              ],
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
                      '暂无账户列表，请从仪表盘进入或稍后重试',
                      style: AppFinanceStyle.labelTextStyle(context),
                    ),
                  )
                : _loading && _rows.isEmpty
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppFinanceStyle.profitGreenEnd,
                        ),
                      )
                    : Scrollbar(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SingleChildScrollView(
                            child: Theme(
                              data: Theme.of(context).copyWith(
                                dividerColor: _tableBorder,
                                dataTableTheme: DataTableThemeData(
                                  headingTextStyle: _headerStyle,
                                  dataTextStyle: _cellStyle,
                                  dividerThickness: 1,
                                  horizontalMargin: 12,
                                  columnSpacing: 16,
                                ),
                              ),
                              child: DataTable(
                                headingRowColor: WidgetStateProperty.all(
                                  const Color(0xFF252532),
                                ),
                                dataRowColor: WidgetStateProperty.resolveWith(
                                  (states) => states.contains(WidgetState.hovered)
                                      ? const Color(0xFF1A1A22)
                                      : const Color(0xFF12121a),
                                ),
                                border: TableBorder.symmetric(
                                  inside: BorderSide(
                                    color: _tableBorder,
                                    width: 0.5,
                                  ),
                                ),
                                columns: [
                                  DataColumn(label: _headerCell('标的')),
                                  DataColumn(label: _headerCell('合约')),
                                  DataColumn(label: _headerCell('方向')),
                                  DataColumn(label: _headerCell('保证金')),
                                  DataColumn(label: _headerCell('杠杆(x)')),
                                  DataColumn(label: _headerCell('开仓均价')),
                                  DataColumn(label: _headerCell('平仓均价')),
                                  DataColumn(label: _headerCell('最大持仓量')),
                                  DataColumn(label: _headerCell('平仓量')),
                                  DataColumn(label: _headerCell('已实现盈亏')),
                                  DataColumn(label: _headerCell('盈亏%')),
                                  DataColumn(label: _headerCell('手续费')),
                                  DataColumn(label: _headerCell('资金费')),
                                  DataColumn(label: _headerCell('开仓时间(UTC)')),
                                  DataColumn(label: _headerCell('更新时间(UTC)')),
                                  DataColumn(label: _headerCell('平仓类型')),
                                ],
                                rows: _rows.map((r) {
                                  final pnlShow =
                                      r.realizedPnl ?? r.pnl;
                                  final pnlC = _pnlColor(pnlShow);
                                  return DataRow(
                                    cells: [
                                      DataCell(_cell(r.instId)),
                                      DataCell(_cell(r.instType)),
                                      DataCell(_sideCell(r.posSide)),
                                      DataCell(_cell(_mgnLabel(r.mgnMode))),
                                      DataCell(_cell(r.lever)),
                                      DataCell(_cell(r.openAvgPx)),
                                      DataCell(_cell(r.closeAvgPx)),
                                      DataCell(_cell(r.openMaxPos)),
                                      DataCell(_cell(r.closeTotalPos)),
                                      DataCell(
                                        _cell(
                                          pnlShow,
                                          color: pnlC,
                                        ),
                                      ),
                                      DataCell(_cell(r.pnlRatio)),
                                      DataCell(
                                        _cell(
                                          r.fee,
                                          color: _pnlColor(r.fee),
                                        ),
                                      ),
                                      DataCell(
                                        _cell(
                                          r.fundingFee,
                                          color: _pnlColor(r.fundingFee),
                                        ),
                                      ),
                                      DataCell(_cell(_formatUtcMs(r.cTimeMs))),
                                      DataCell(_cell(_formatUtcMs(r.uTimeMs))),
                                      DataCell(_cell(r.closeType)),
                                    ],
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
                      ),
          ),
          if (_nextBefore != null && _rows.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton(
                onPressed: _loading ? null : () => _load(append: true),
                child: Text(_loading ? '加载中…' : '加载更多'),
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
          '历史仓位',
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
}
