import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../utils/number_display_format.dart';
import '../../widgets/water_background.dart';

/// 与 [Account_List.json] 中对比表一致的五列顺序（account_id → 表头简称）
const List<({String accountId, String columnTitle, String tag})>
kAccountPerformanceColumns = [
  (accountId: 'HzTech_MainRepo', columnTitle: '主账户', tag: '对外的门面，颜值担当'),
  (accountId: 'HzTech_Moneyflow@001', columnTitle: '001', tag: '现金流'),
  (accountId: 'HzTech_Moneyflow@002', columnTitle: '002', tag: 'Defi项目专属'),
  (accountId: 'HzTech_Moneyflow@003', columnTitle: '003', tag: '复利'),
  (accountId: 'HzTech_Moneyflow@004', columnTitle: '004', tag: '董哥专属'),
];

/// Web：策略分析师多账户持仓（OKX 实时）与选定 UTC 自然月平仓汇总对比。
class WebAccountPerformanceScreen extends StatefulWidget {
  const WebAccountPerformanceScreen({
    super.key,
    this.embedInShell = true,
    this.sharedBots = const [],
  });

  final bool embedInShell;
  final List<UnifiedTradingBot> sharedBots;

  @override
  State<WebAccountPerformanceScreen> createState() =>
      _WebAccountPerformanceScreenState();
}

class _WebAccountPerformanceScreenState
    extends State<WebAccountPerformanceScreen> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _bots = [];
  int _year = DateTime.now().toUtc().year;
  int _month = DateTime.now().toUtc().month;
  bool _loading = true;
  String? _loadError;

  /// 各列与 [kAccountPerformanceColumns] 顺序一致
  List<_ColumnData> _columns = [];
  double? _refPrice;
  int? _highlightShortCostIndex;

  @override
  void initState() {
    super.initState();
    _bots = List.from(widget.sharedBots);
    _load();
  }

  @override
  void didUpdateWidget(covariant WebAccountPerformanceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sharedBots != widget.sharedBots &&
        widget.sharedBots.isNotEmpty) {
      _bots = List.from(widget.sharedBots);
      _load();
    }
  }

  Future<void> _ensureBots() async {
    if (_bots.isNotEmpty) return;
    final baseUrl = await _prefs.backendBaseUrl;
    final token = await _prefs.authToken;
    final api = ApiClient(baseUrl, token: token);
    final r = await api.getTradingBots();
    if (!mounted) return;
    setState(() => _bots = r.botList);
  }

  Future<void> _load() async {
    await _ensureBots();
    if (!mounted) return;
    if (_bots.isEmpty) {
      setState(() {
        _loading = false;
        _loadError = '暂无交易账户';
        _columns = [];
      });
      return;
    }

    setState(() {
      _loading = true;
      _loadError = null;
    });

    final baseUrl = await _prefs.backendBaseUrl;
    final token = await _prefs.authToken;
    final api = ApiClient(baseUrl, token: token);

    try {
      final profitResp = await api.getAccountProfit();
      final byBot = <String, AccountProfit>{
        for (final a in profitResp.accounts ?? const <AccountProfit>[])
          if (a.botId.isNotEmpty) a.botId: a,
      };

      final botIds = {for (final b in _bots) b.tradingbotId};
      final columnSpecs = kAccountPerformanceColumns
          .where((s) => botIds.contains(s.accountId))
          .toList();

      Future<_ColumnData> loadColumn(
        ({String accountId, String columnTitle, String tag}) spec,
      ) async {
        if (!botIds.contains(spec.accountId)) {
          return _ColumnData.missing(spec);
        }
        final pnl = await api.getDailyRealizedPnl(
          spec.accountId,
          _year,
          _month,
        );
        final pos = await api.getTradingbotPositions(spec.accountId);
        final ap = byBot[spec.accountId];
        final agg = _aggregatePositions(pos.positions);
        var posErr = pos.positionsError;
        if (!pnl.success) {
          final m = pnl.message?.trim();
          if (m != null && m.isNotEmpty) {
            posErr = (posErr == null || posErr.isEmpty) ? m : '$posErr; $m';
          }
        }
        final monthPnl =
            pnl.monthTotalPnl ??
            pnl.days.fold<double>(0, (s, d) => s + d.netPnl);
        final closeSum = pnl.days.fold<int>(0, (s, d) => s + d.closeCount);
        final initial = ap?.initialBalance ?? 0;
        final retPct = initial > 1e-6
            ? (monthPnl / initial) * 100.0
            : double.nan;

        return _ColumnData(
          spec: spec,
          profit: ap,
          agg: agg,
          positionsError: posErr,
          monthCloseCount: closeSum,
          monthPnl: monthPnl,
          monthReturnPct: retPct,
        );
      }

      final cols = await Future.wait(
        columnSpecs.map(loadColumn),
      );

      if (!mounted) return;

      double? refPx;
      final marks = cols
          .map((c) => c.agg?.refMarkPx)
          .whereType<double>()
          .where((x) => x > 0)
          .toList();
      if (marks.isNotEmpty) {
        refPx = marks.reduce(math.max);
      }

      int? hi;
      final shorts = <double>[];
      for (var i = 0; i < cols.length; i++) {
        final s = cols[i].agg?.shortAvgPx ?? 0;
        if (s > 0) shorts.add(s);
      }
      if (shorts.length >= 3) {
        final sorted = List<double>.from(shorts)..sort();
        final mid = sorted[sorted.length ~/ 2];
        var bestI = -1;
        var bestD = 0.0;
        for (var i = 0; i < cols.length; i++) {
          final s = cols[i].agg?.shortAvgPx ?? 0;
          if (s <= 0) continue;
          final d = (s - mid).abs();
          if (d > bestD && d >= 25) {
            bestD = d;
            bestI = i;
          }
        }
        if (bestI >= 0) hi = bestI;
      }

      setState(() {
        _columns = cols;
        _refPrice = refPx;
        _highlightShortCostIndex = hi;
        _loading = false;
      });
    } catch (e, st) {
      debugPrint('WebAccountPerformanceScreen load $e\n$st');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.toString();
        _columns = [];
      });
    }
  }

  void _shiftMonth(int delta) {
    var y = _year;
    var m = _month + delta;
    while (m < 1) {
      m += 12;
      y -= 1;
    }
    while (m > 12) {
      m -= 12;
      y += 1;
    }
    if (y < 2000 || y > 2100) return;
    setState(() {
      _year = y;
      _month = m;
    });
    _load();
  }

  String _monthTitle() => '$_year年$_month月（UTC 自然月）';

  /// 数据快照日期（UTC 当天），与对比月份独立。
  String _snapshotDateCompact() {
    final n = DateTime.now().toUtc();
    return '${n.year}'
        '${n.month.toString().padLeft(2, '0')}'
        '${n.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final body = ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: RefreshIndicator(
          onRefresh: _load,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              24,
              widget.embedInShell ? 16 : 12,
              24,
              48,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1280),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MonthToolbar(
                      title: _monthTitle(),
                      onPrev: () => _shiftMonth(-1),
                      onNext: () => _shiftMonth(1),
                      onThisMonth: () {
                        final n = DateTime.now().toUtc();
                        setState(() {
                          _year = n.year;
                          _month = n.month;
                        });
                        _load();
                      },
                    ),
                    const SizedBox(height: 12),
                    if (_loadError != null)
                      FinanceCard(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _loadError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      )
                    else if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(48),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FinanceCard(
                            padding: const EdgeInsets.all(20),
                            child: _ComparisonGrid(
                              dateCompact: _snapshotDateCompact(),
                              refPrice: _refPrice,
                              columns: _columns,
                              highlightShortCostIndex: _highlightShortCostIndex,
                              year: _year,
                              month: _month,
                            ),
                          ),
                          if (_columns.any(
                            (c) => (c.positionsError ?? '').isNotEmpty,
                          )) ...[
                            const SizedBox(height: 12),
                            FinanceCard(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '持仓 / 月度盈亏接口提示',
                                    style:
                                        AppFinanceStyle.labelTextStyle(
                                          context,
                                        ).copyWith(
                                          color: AppFinanceStyle.valueColor,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  ..._columns
                                      .where(
                                        (c) =>
                                            (c.positionsError ?? '').isNotEmpty,
                                      )
                                      .map(
                                        (c) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 4,
                                          ),
                                          child: Text(
                                            '${c.spec.columnTitle}（${c.spec.accountId}）：${c.positionsError}',
                                            style:
                                                AppFinanceStyle.labelTextStyle(
                                                  context,
                                                ).copyWith(fontSize: 12),
                                          ),
                                        ),
                                      ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.embedInShell) return body;

    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '账户绩效对比',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(
            color: AppFinanceStyle.valueColor,
            fontSize: 18,
            fontWeight: FontWeight.w600,
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

class _MonthToolbar extends StatelessWidget {
  const _MonthToolbar({
    required this.title,
    required this.onPrev,
    required this.onNext,
    required this.onThisMonth,
  });

  final String title;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onThisMonth;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '对比月份',
          style: AppFinanceStyle.labelTextStyle(
            context,
          ).copyWith(fontWeight: FontWeight.w600),
        ),
        IconButton(
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left),
          color: AppFinanceStyle.valueColor,
          tooltip: '上一月',
        ),
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AppFinanceStyle.valueColor,
            fontWeight: FontWeight.w700,
          ),
        ),
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
          color: AppFinanceStyle.valueColor,
          tooltip: '下一月',
        ),
        TextButton(onPressed: onThisMonth, child: const Text('本月')),
      ],
    );
  }
}

class _PosAgg {
  _PosAgg({
    required this.longQty,
    required this.shortQty,
    required this.longAvgPx,
    required this.shortAvgPx,
    required this.totalUpl,
    this.refMarkPx,
  });

  final double longQty;
  final double shortQty;
  final double longAvgPx;
  final double shortAvgPx;
  final double totalUpl;
  final double? refMarkPx;

  double get qtyGap => (shortQty - longQty).abs();
  double get costGap =>
      shortAvgPx > 0 && longAvgPx > 0 ? shortAvgPx - longAvgPx : double.nan;
}

_PosAgg _aggregatePositions(List<OkxPosition> positions) {
  if (positions.isEmpty) {
    return _PosAgg(
      longQty: 0,
      shortQty: 0,
      longAvgPx: 0,
      shortAvgPx: 0,
      totalUpl: 0,
      refMarkPx: null,
    );
  }
  var lq = 0.0;
  var sq = 0.0;
  var lNotional = 0.0;
  var sNotional = 0.0;
  var uplSum = 0.0;
  double? refPx;

  for (final p in positions) {
    uplSum += p.upl;
    final px = p.displayPrice;
    if (px > 0) {
      final r = refPx;
      refPx = r == null ? px : math.max(r, px);
    }
    final side = p.posSide.toLowerCase();
    final pos = p.pos;
    if (side == 'net') {
      if (pos > 1e-12) {
        lq += pos;
        lNotional += pos * p.avgPx;
      } else if (pos < -1e-12) {
        final a = pos.abs();
        sq += a;
        sNotional += a * p.avgPx;
      }
    } else if (side == 'long') {
      final a = pos.abs();
      lq += a;
      lNotional += a * p.avgPx;
    } else if (side == 'short') {
      final a = pos.abs();
      sq += a;
      sNotional += a * p.avgPx;
    }
  }

  return _PosAgg(
    longQty: lq,
    shortQty: sq,
    longAvgPx: lq > 1e-12 ? lNotional / lq : 0,
    shortAvgPx: sq > 1e-12 ? sNotional / sq : 0,
    totalUpl: uplSum,
    refMarkPx: refPx,
  );
}

class _ColumnData {
  _ColumnData({
    required this.spec,
    this.profit,
    this.agg,
    this.positionsError,
    required this.monthCloseCount,
    required this.monthPnl,
    required this.monthReturnPct,
  });

  factory _ColumnData.missing(
    ({String accountId, String columnTitle, String tag}) spec,
  ) {
    return _ColumnData(
      spec: spec,
      profit: null,
      agg: null,
      positionsError: '未在交易账户列表中',
      monthCloseCount: 0,
      monthPnl: 0,
      monthReturnPct: double.nan,
    );
  }

  final ({String accountId, String columnTitle, String tag}) spec;
  final AccountProfit? profit;
  final _PosAgg? agg;
  final String? positionsError;
  final int monthCloseCount;
  final double monthPnl;
  final double monthReturnPct;

  String _fmtQty(double v) {
    if (!v.isFinite) return '—';
    if (v.abs() < 1e-9) return '0';
    if ((v - v.round()).abs() < 1e-6) return formatUiInteger(v);
    return v.toStringAsFixed(2);
  }

  String _fmtPx(double v) {
    if (!v.isFinite || v <= 0) return '—';
    return v.round().toString();
  }

  String _fmtGap(double v) {
    if (!v.isFinite) return '—';
    return v.round().toString();
  }

  String get _floatRow =>
      agg == null ? '—' : formatUiSignedUsdt2(agg!.totalUpl);
}

class _ComparisonGrid extends StatelessWidget {
  const _ComparisonGrid({
    required this.dateCompact,
    required this.refPrice,
    required this.columns,
    required this.highlightShortCostIndex,
    required this.year,
    required this.month,
  });

  final String dateCompact;
  final double? refPrice;
  final List<_ColumnData> columns;
  final int? highlightShortCostIndex;
  final int year;
  final int month;

  static const Color _gridColor = Color(0xFF3a3a48);
  static const Color _tagBlue = Color(0xFF2563EB);
  static const Color _highlightYellow = Color(0xFFFFF176);

  static const double _labelW = 168;
  static const double _cellW = 92;
  static const double _remarkMinW = 200;

  @override
  Widget build(BuildContext context) {
    final baseStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontSize: 13,
      color: AppFinanceStyle.valueColor,
      height: 1.35,
    );
    final labelStyle = baseStyle?.copyWith(
      color: AppFinanceStyle.labelColor,
      fontWeight: FontWeight.w500,
    );

    final priceText = refPrice != null && refPrice! > 0
        ? refPrice!.round().toString()
        : '—';

    final rows = <List<Widget>>[];

    rows.add([
      _cell(
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            dateCompact,
            style: labelStyle?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppFinanceStyle.valueColor,
            ),
          ),
        ),
        _labelW,
      ),
      _cell(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Text(
            '当前价格　$priceText',
            textAlign: TextAlign.center,
            style: baseStyle?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
        5 * _cellW,
      ),
      _flexCell(context, const SizedBox.shrink()),
    ]);

    rows.add(_headerRow(context));
    rows.add(_baseRow(context, labelStyle, baseStyle));
    rows.add(_tagRow(context, labelStyle));

    final metricSpecs =
        <
          ({
            String label,
            String Function(_ColumnData c, int i) value,
            bool bold,
            bool Function(_ColumnData c, int i)? useHighlight,
          })
        >[
          (
            label: '多-数量',
            value: (c, _) => c.agg == null ? '—' : c._fmtQty(c.agg!.longQty),
            bold: false,
            useHighlight: null,
          ),
          (
            label: '多-成本线',
            value: (c, _) => c.agg == null ? '—' : c._fmtPx(c.agg!.longAvgPx),
            bold: false,
            useHighlight: null,
          ),
          (
            label: '空-数量',
            value: (c, _) => c.agg == null ? '—' : c._fmtQty(c.agg!.shortQty),
            bold: false,
            useHighlight: null,
          ),
          (
            label: '空-成本线',
            value: (c, _) => c.agg == null ? '—' : c._fmtPx(c.agg!.shortAvgPx),
            bold: false,
            useHighlight: (c, i) =>
                highlightShortCostIndex != null && highlightShortCostIndex == i,
          ),
          (
            label: '数量差距',
            value: (c, _) => c.agg == null ? '—' : c._fmtGap(c.agg!.qtyGap),
            bold: false,
            useHighlight: null,
          ),
          (
            label: '成本差距',
            value: (c, _) {
              final g = c.agg?.costGap ?? double.nan;
              if (!g.isFinite) return '—';
              return g.round().toString();
            },
            bold: false,
            useHighlight: null,
          ),
          (
            label: '资产余额',
            value: (c, _) => formatUiIntegerOpt(c.profit?.currentBalance),
            bold: false,
            useHighlight: null,
          ),
          (
            label: '浮动盈亏(upl)',
            value: (c, _) => c._floatRow,
            bold: false,
            useHighlight: null,
          ),
          (
            label: '权益金额',
            value: (c, _) => formatUiIntegerOpt(c.profit?.equityUsdt),
            bold: false,
            useHighlight: null,
          ),
          (
            label: '交割数量-$month月',
            value: (c, _) => c.monthCloseCount.toString(),
            bold: false,
            useHighlight: null,
          ),
          (
            label: '收益金额-$month月',
            value: (c, _) => formatUiSignedUsdt2(c.monthPnl),
            bold: false,
            useHighlight: null,
          ),
          (
            label: '收益率-$month月',
            value: (c, _) => formatUiPercentLabel(c.monthReturnPct),
            bold: true,
            useHighlight: null,
          ),
        ];

    for (final spec in metricSpecs) {
      rows.add([
        _cell(
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Text(spec.label, style: labelStyle),
          ),
          _labelW,
        ),
        ...List.generate(columns.length, (ci) {
          final c = columns[ci];
          final hl = spec.useHighlight?.call(c, ci) ?? false;
          final t = spec.value(c, ci);
          return _cell(
            Container(
              color: hl ? _highlightYellow : null,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
              alignment: Alignment.center,
              child: Text(
                t,
                textAlign: TextAlign.center,
                style:
                    (spec.bold
                            ? baseStyle?.copyWith(fontWeight: FontWeight.w800)
                            : baseStyle)
                        ?.copyWith(
                          color: hl
                              ? const Color(0xFF1a1a1a)
                              : baseStyle?.color,
                        ),
              ),
            ),
            _cellW,
          );
        }),
        _flexCell(
          context,
          Container(
            color: spec.label == '空-成本线' && highlightShortCostIndex != null
                ? _highlightYellow
                : null,
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            alignment: Alignment.centerLeft,
            child: Text(
              _remarkForRow(
                spec.label,
                showShortCostHint:
                    spec.label == '空-成本线' && highlightShortCostIndex != null,
              ),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: 12,
                color: spec.label == '空-成本线' && highlightShortCostIndex != null
                    ? const Color(0xFF1a1a1a)
                    : AppFinanceStyle.valueColor,
                height: 1.35,
              ),
            ),
          ),
        ),
      ]);
    }

    final grid = Container(
      decoration: BoxDecoration(
        border: Border.all(color: _gridColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows.map((cells) {
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: cells,
            ),
          );
        }).toList(),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = _labelW + columns.length * _cellW + _remarkMinW;
        if (constraints.maxWidth >= w + 48) return grid;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: w, child: grid),
        );
      },
    );
  }

  List<Widget> _headerRow(BuildContext context) {
    return [
      _cell(
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            '指标',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 12,
              color: AppFinanceStyle.labelColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _labelW,
      ),
      ...columns.map(
        (c) => _cell(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Text(
              c.spec.columnTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: 13,
                color: AppFinanceStyle.valueColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          _cellW,
        ),
      ),
      _flexCell(
        context,
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            '备注',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 12,
              color: AppFinanceStyle.labelColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _baseRow(
    BuildContext context,
    TextStyle? labelStyle,
    TextStyle? baseStyle,
  ) {
    return [
      _cell(
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('基数', style: labelStyle),
        ),
        _labelW,
      ),
      ...columns.map(
        (c) => _cell(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            child: Text(
              formatUiIntegerOpt(c.profit?.initialBalance),
              textAlign: TextAlign.center,
              style: baseStyle,
            ),
          ),
          _cellW,
        ),
      ),
      _flexCell(context, const SizedBox.shrink()),
    ];
  }

  List<Widget> _tagRow(BuildContext context, TextStyle? labelStyle) {
    return [
      _cell(
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('说明', style: labelStyle),
        ),
        _labelW,
      ),
      ...columns.map(
        (c) => _cell(
          Padding(
            padding: const EdgeInsets.all(6),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _tagBlue,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                child: Text(
                  c.spec.tag,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: Colors.white,
                    height: 1.25,
                  ),
                ),
              ),
            ),
          ),
          _cellW,
        ),
      ),
      _flexCell(context, const SizedBox.shrink()),
    ];
  }

  String _remarkForRow(String label, {bool showShortCostHint = false}) {
    if (label == '空-成本线' && showShortCostHint) {
      return '空成本偏离各列中位数较多';
    }
    if (label.startsWith('交割') ||
        label.startsWith('收益') ||
        label.startsWith('收益率')) {
      return 'UTC $year-${month.toString().padLeft(2, '0')} 平仓汇总';
    }
    if (label == '浮动盈亏(upl)') {
      return 'Σ OKX upl，与持仓接口一致';
    }
    return '';
  }

  Widget _cell(Widget child, double width) {
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: _gridColor, width: 1),
            bottom: BorderSide(color: _gridColor, width: 1),
          ),
        ),
        child: child,
      ),
    );
  }

  Widget _flexCell(BuildContext context, Widget child) {
    return Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _gridColor, width: 1)),
        ),
        child: child,
      ),
    );
  }
}
