import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../constants/poll_intervals.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../utils/network_error_message.dart';
import '../../utils/number_display_format.dart';
import '../../widgets/water_background.dart';

/// Web「账号下单」：多账户 Tab；持仓、委托、日线 ATR 参考、OKX 风格市价/限价与开平/平衡（交易员/管理员）。
class WebAccountOrderScreen extends StatefulWidget {
  const WebAccountOrderScreen({
    super.key,
    this.sharedBots = const [],
    this.periodicRefreshActive = true,
  });

  final List<UnifiedTradingBot> sharedBots;
  final bool periodicRefreshActive;

  @override
  State<WebAccountOrderScreen> createState() => _WebAccountOrderScreenState();
}

class _WebAccountOrderScreenState extends State<WebAccountOrderScreen>
    with SingleTickerProviderStateMixin {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _bots = [];
  TabController? _tabController;
  int _tabLen = 0;

  @override
  void initState() {
    super.initState();
    _bots = List<UnifiedTradingBot>.from(widget.sharedBots);
    _syncTabController();
    if (_bots.isEmpty) {
      unawaited(_loadBots());
    }
  }

  @override
  void didUpdateWidget(covariant WebAccountOrderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sharedBots != oldWidget.sharedBots) {
      _bots = List<UnifiedTradingBot>.from(widget.sharedBots);
      _syncTabController();
    }
  }

  void _syncTabController() {
    final n = _bots.length;
    if (n == _tabLen && _tabController != null) return;
    _tabController?.dispose();
    _tabLen = n;
    if (n <= 0) {
      _tabController = null;
      return;
    }
    _tabController = TabController(length: n, vsync: this);
    _tabController!.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _loadBots() async {
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.getTradingBots();
      if (!mounted) return;
      setState(() {
        _bots = resp.botList;
        _syncTabController();
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_bots.isEmpty) {
      return WaterBackground(
        child: Center(
          child: Text(
            _tabController == null ? '正在加载账户列表…' : '无可用交易账户',
            style: AppFinanceStyle.labelTextStyle(context),
          ),
        ),
      );
    }
    final tc = _tabController!;
    final idx = tc.index.clamp(0, _bots.length - 1);
    return WaterBackground(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: const Color(0xFF12121a),
            child: TabBar(
              controller: tc,
              isScrollable: true,
              labelColor: AppFinanceStyle.valueColor,
              unselectedLabelColor: AppFinanceStyle.labelColor,
              indicatorColor: AppFinanceStyle.profitGreenEnd,
              tabs: [
                for (final b in _bots)
                  Tab(
                    text: (b.tradingbotName?.trim().isNotEmpty ?? false)
                        ? b.tradingbotName!.trim()
                        : b.tradingbotId,
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: tc,
              children: [
                for (var i = 0; i < _bots.length; i++)
                  _AccountOrderTabBody(
                    key: ValueKey<String>(_bots[i].tradingbotId),
                    bot: _bots[i],
                    periodicRefreshActive:
                        widget.periodicRefreshActive && i == idx,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _swapInstIdHeuristic(UnifiedTradingBot b) {
  final s = (b.symbol ?? '').trim();
  if (s.isEmpty) return 'PEPE-USDT-SWAP';
  final u = s.toUpperCase();
  if (u.endsWith('-SWAP')) return s;
  if (s.contains('/')) {
    final parts = s.split('/');
    if (parts.length >= 2) {
      final base = parts[0].trim();
      final quote = parts[1].split(':').first.trim();
      if (base.isNotEmpty && quote.isNotEmpty) {
        return '$base-$quote-SWAP';
      }
    }
  }
  if (u.contains('-') && !u.contains('SWAP')) {
    return '$s-SWAP';
  }
  return s;
}

class _AccountOrderTabBody extends StatefulWidget {
  const _AccountOrderTabBody({
    super.key,
    required this.bot,
    required this.periodicRefreshActive,
  });

  final UnifiedTradingBot bot;
  final bool periodicRefreshActive;

  @override
  State<_AccountOrderTabBody> createState() => _AccountOrderTabBodyState();
}

class _AccountOrderTabBodyState extends State<_AccountOrderTabBody> {
  final _prefs = SecurePrefs();
  final _szController = TextEditingController();
  final _limitPxController = TextEditingController();

  bool _loading = true;
  String? _error;
  List<OkxPosition> _positions = [];
  List<PendingOrderRow> _orders = [];
  String? _ordersError;
  StrategyDailyEfficiencyResponse? _eff;
  OpenPositionsSnapshotRow? _snap;
  double? _tickerLast;
  String _resolvedInst = '';
  bool _autoTp = false;
  String _ordType = 'market'; // market | limit
  bool _actionBusy = false;

  Timer? _poll;

  String get _bid => widget.bot.tradingbotId;

  @override
  void initState() {
    super.initState();
    _resolvedInst = _swapInstIdHeuristic(widget.bot);
    unawaited(_pull());
    _syncPollTimer();
  }

  void _syncPollTimer() {
    _poll?.cancel();
    _poll = null;
    if (!widget.periodicRefreshActive) return;
    _poll = Timer.periodic(PollIntervals.mediumPoll, (_) {
      if (widget.periodicRefreshActive && mounted) {
        unawaited(_pull(silent: true));
      }
    });
  }

  @override
  void didUpdateWidget(covariant _AccountOrderTabBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.periodicRefreshActive != widget.periodicRefreshActive) {
      _syncPollTimer();
      if (widget.periodicRefreshActive) {
        unawaited(_pull(silent: true));
      }
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _szController.dispose();
    _limitPxController.dispose();
    super.dispose();
  }

  Future<void> _pull({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final inst0 = _resolvedInst;
      final posF = api.getTradingbotPositions(_bid);
      final ordF = api.getPendingOrders(_bid);
      final effF = api.getStrategyDailyEfficiency(
        _bid,
        instId: inst0,
        days: 40,
      );
      final snapF = api.getOpenPositionsSnapshots(_bid, limit: 80);
      final tickF = api.getAccountTicker(_bid, instId: inst0);
      final results = await Future.wait<Object?>([
        posF,
        ordF,
        effF,
        snapF,
        tickF,
      ]);
      if (!mounted) return;
      final pos = results[0]! as OkxPositionsResponse;
      final ord = results[1]! as PendingOrdersResponse;
      final eff = results[2]! as StrategyDailyEfficiencyResponse;
      final snap = results[3]! as OpenPositionsSnapshotsResponse;
      final tickMap = results[4]! as Map<String, dynamic>;

      var inst = inst0;
      if (pos.positions.isNotEmpty) {
        final first = pos.positions.first.instId;
        if (first.isNotEmpty) {
          inst = first;
        }
      }
      OpenPositionsSnapshotRow? snapRow;
      for (final r in snap.rows) {
        if (r.instId == inst) {
          snapRow = r;
          break;
        }
      }
      snapRow ??= snap.rows.isNotEmpty ? snap.rows.first : null;

      final last = (tickMap['last'] as num?)?.toDouble();
      setState(() {
        _positions = pos.positions;
        _orders = ord.orders;
        _ordersError = ord.ordersError;
        _eff = eff;
        _snap = snapRow;
        _tickerLast = last;
        _resolvedInst = inst;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (!silent) {
          _loading = false;
        }
        _error = friendlyNetworkError(e);
      });
    }
  }

  StrategyDailyEfficiencyRow? _latestEffRow() {
    final rows = _eff?.rows ?? const <StrategyDailyEfficiencyRow>[];
    for (final r in rows) {
      if (r.atr14 != null && r.atr14! > 0) {
        return r;
      }
    }
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<void> _execute(String op) async {
    final szText = _szController.text.trim();
    final body = <String, dynamic>{
      'op': op,
      'inst_id': _resolvedInst,
      'auto_tp': _autoTp,
      'ord_type': _ordType,
    };
    if (szText.isNotEmpty &&
        (op == 'open_long' ||
            op == 'open_short' ||
            op == 'close_long' ||
            op == 'close_short')) {
      body['sz'] = num.tryParse(szText) ?? szText;
    }
    if (_ordType == 'limit' &&
        (op == 'open_long' || op == 'open_short') &&
        _limitPxController.text.trim().isNotEmpty) {
      body['limit_px'] = num.tryParse(_limitPxController.text.trim()) ??
          _limitPxController.text.trim();
    }
    setState(() => _actionBusy = true);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final res = await api.postAccountTradeExecute(_bid, body);
      if (!mounted) return;
      final buf = StringBuffer(res.message);
      for (final s in res.steps) {
        buf.writeln('${s.name}: ${s.ok ? "OK" : "失败"} ${s.detail}');
      }
      for (final w in res.warnings) {
        buf.writeln('⚠ $w');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            res.success ? '已提交\n$buf' : '失败\n$buf',
            maxLines: 8,
          ),
          backgroundColor:
              res.success ? AppFinanceStyle.profitGreenEnd : AppFinanceStyle.textLoss,
        ),
      );
      await _pull();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyNetworkError(e))),
      );
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _confirm(String title, String op) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a24),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(
          '确认对 $_resolvedInst 执行 $op？',
          style: TextStyle(color: AppFinanceStyle.labelColor),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (ok == true) await _execute(op);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _positions.isEmpty && _eff == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final erow = _latestEffRow();
    final atr = erow?.atr14;
    final th1 = erow?.threshold01AtrPrice;
    final th6 = erow?.threshold06AtrPrice;
    final th12 = erow?.threshold12AtrPrice;
    final refPx = _tickerLast ??
        (_positions.isNotEmpty ? _positions.first.displayPrice : null) ??
        _snap?.lastPx;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: AppFinanceStyle.textLoss),
                ),
              ),
            _infoStrip(
              context,
              refPx: refPx,
              atr: atr,
              th1: th1,
              th6: th6,
              th12: th12,
            ),
            const SizedBox(height: 12),
            Text(
              '强平价口径：入库快照 account_open_positions_snapshots（最新一行）；'
              '距强平价 = 强平价 − 现价，与绩效赛马一致。',
              style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 11),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (ctx, c) {
                final wide = c.maxWidth >= 960;
                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 1, child: _positionsCard(context)),
                      const SizedBox(width: 12),
                      Expanded(flex: 1, child: _ordersCard(context)),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _positionsCard(context),
                    const SizedBox(height: 12),
                    _ordersCard(context),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            _orderPanel(context),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: _loading ? null : _pull,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新数据'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoStrip(
    BuildContext context, {
    required double? refPx,
    required double? atr,
    required double? th1,
    required double? th6,
    required double? th12,
  }) {
    final snap = _snap;
    String liqLine(String label, double liq) {
      if (refPx == null || !refPx.isFinite || liq <= 0) {
        return '$label 强平价 ${liq > 0 ? formatUiInteger(liq * 1e9) : "—"}';
      }
      final dist = liq - refPx;
      return '$label 强平价 ${formatUiInteger(liq * 1e9)} · 距强平 ${formatUiSignedInteger(dist * 1e9)}（×1e9）';
    }

    return Card(
      color: const Color(0xFF16161f),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '合约 $_resolvedInst · 现价 ${refPx != null && refPx.isFinite ? formatUiInteger(refPx * 1e9) : "—"}（×1e9）',
              style: AppFinanceStyle.valueTextStyle(context).copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '日线 ATR(14)：${atr != null && atr > 0 ? atr.toStringAsFixed(8) : "—"}',
              style: AppFinanceStyle.labelTextStyle(context),
            ),
            Text(
              '止盈价差 0.1×ATR：${th1 != null && th1 > 0 ? th1.toStringAsFixed(8) : "—"} · '
              '加仓参考 0.6×ATR：${th6 != null && th6 > 0 ? th6.toStringAsFixed(8) : "—"} · '
              '1.2×ATR：${th12 != null && th12 > 0 ? th12.toStringAsFixed(8) : "—"}（仅展示，不自动加仓）',
              style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
            ),
            if (snap != null) ...[
              const SizedBox(height: 6),
              Text(
                '多仓 ${formatUiInteger(snap.longPosSize)} 张 · 空仓 ${formatUiInteger(snap.shortPosSize)} 张',
                style: AppFinanceStyle.labelTextStyle(context),
              ),
              Text(
                liqLine('多', snap.longLiqPx),
                style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
              ),
              Text(
                liqLine('空', snap.shortLiqPx),
                style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _positionsCard(BuildContext context) {
    return Card(
      color: const Color(0xFF16161f),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前持仓（OKX 实时）', style: AppFinanceStyle.valueTextStyle(context)),
            const Divider(),
            if (_positions.isEmpty)
              Text('无持仓', style: AppFinanceStyle.labelTextStyle(context))
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 36,
                  dataRowMaxHeight: 48,
                  columns: const [
                    DataColumn(label: Text('合约')),
                    DataColumn(label: Text('方向')),
                    DataColumn(label: Text('张数')),
                    DataColumn(label: Text('均价×1e9')),
                    DataColumn(label: Text('价×1e9')),
                    DataColumn(label: Text('UPL')),
                    DataColumn(label: Text('强平价×1e9')),
                  ],
                  rows: [
                    for (final p in _positions)
                      DataRow(
                        cells: [
                          DataCell(Text(p.instId, style: const TextStyle(fontSize: 12))),
                          DataCell(Text(p.posSide)),
                          DataCell(Text(p.pos.abs().toString())),
                          DataCell(Text(formatUiInteger(p.avgPx * 1e9))),
                          DataCell(Text(formatUiInteger(p.displayPrice * 1e9))),
                          DataCell(Text(formatUiSignedUsdt2(p.upl))),
                          DataCell(Text(
                            p.liqPx > 0 ? formatUiInteger(p.liqPx * 1e9) : '—',
                          )),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _ordersCard(BuildContext context) {
    return Card(
      color: const Color(0xFF16161f),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前委托', style: AppFinanceStyle.valueTextStyle(context)),
            if (_ordersError != null && _ordersError!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _ordersError!,
                  style: TextStyle(color: AppFinanceStyle.textLoss, fontSize: 12),
                ),
              ),
            const Divider(),
            if (_orders.isEmpty)
              Text('无委托', style: AppFinanceStyle.labelTextStyle(context))
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 36,
                  dataRowMaxHeight: 48,
                  columns: const [
                    DataColumn(label: Text('合约')),
                    DataColumn(label: Text('方向')),
                    DataColumn(label: Text('pos')),
                    DataColumn(label: Text('类型')),
                    DataColumn(label: Text('价')),
                    DataColumn(label: Text('张数')),
                    DataColumn(label: Text('成交')),
                    DataColumn(label: Text('状态')),
                  ],
                  rows: [
                    for (final o in _orders)
                      DataRow(
                        cells: [
                          DataCell(Text(o.instId, style: const TextStyle(fontSize: 12))),
                          DataCell(Text(o.side)),
                          DataCell(Text(o.posSide)),
                          DataCell(Text(o.ordType)),
                          DataCell(Text(o.px ?? '—')),
                          DataCell(Text(o.sz ?? '—')),
                          DataCell(Text(o.fillSz ?? '—')),
                          DataCell(Text(o.state)),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _orderPanel(BuildContext context) {
    return Card(
      color: const Color(0xFF16161f),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下单', style: AppFinanceStyle.valueTextStyle(context)),
            const SizedBox(height: 8),
            Text(
              '全仓 cross · 双向 long/short · 默认 50x（与测连 auto_configure 一致）；请先确保账户已对齐。',
              style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _szController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: '张数 sz',
                      labelStyle: TextStyle(color: Colors.white70),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                DropdownButton<String>(
                  value: _ordType,
                  dropdownColor: const Color(0xFF22222c),
                  items: const [
                    DropdownMenuItem(value: 'market', child: Text('市价')),
                    DropdownMenuItem(value: 'limit', child: Text('限价')),
                  ],
                  onChanged: _actionBusy
                      ? null
                      : (v) {
                          if (v != null) setState(() => _ordType = v);
                        },
                ),
                if (_ordType == 'limit')
                  SizedBox(
                    width: 160,
                    child: TextField(
                      controller: _limitPxController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: '限价 px',
                        labelStyle: TextStyle(color: Colors.white70),
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _autoTp,
                      onChanged: _actionBusy
                          ? null
                          : (v) => setState(() => _autoTp = v ?? false),
                    ),
                    Text(
                      '自动挂止盈（ATR×0.1 限价 reduce-only）',
                      style: AppFinanceStyle.labelTextStyle(context),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _opButton('开多', () => _execute('open_long'), Colors.green),
                _opButton('开空', () => _execute('open_short'), Colors.redAccent),
                _opButton('平多', () => _confirm('平多', 'close_long'), Colors.orange),
                _opButton('平空', () => _confirm('平空', 'close_short'), Colors.orange),
                _opButton('全平', () => _confirm('全平', 'close_all'), Colors.deepOrange),
                _opButton(
                  '多空平衡',
                  () => _confirm('多空平衡', 'balance_long_short'),
                  Colors.cyan,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _opButton(String label, VoidCallback onTap, Color color) {
    return FilledButton(
      onPressed: _actionBusy ? null : onTap,
      style: FilledButton.styleFrom(backgroundColor: color),
      child: _actionBusy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }
}
