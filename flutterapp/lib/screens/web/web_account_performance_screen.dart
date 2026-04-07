import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../utils/number_display_format.dart';
import '../../widgets/account_detail_loading_overlay.dart';
import '../../widgets/water_background.dart';

/// Web：Account_List 全账户对比；持仓/成本线来自 [account_open_positions_snapshots]。
/// 对比表中「当前价格 / 多-成本 / 空-成本 / 成本差」为数值 ×1e9 后取整显示。
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

  List<_ColumnData> _columns = [];
  double? _refPrice;

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

  static String _columnTitle(UnifiedTradingBot b) {
    final n = (b.tradingbotName ?? '').trim();
    if (n.isNotEmpty) return n;
    return b.tradingbotId;
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

      final sorted = List<UnifiedTradingBot>.from(_bots)
        ..sort((a, b) => a.tradingbotId.compareTo(b.tradingbotId));

      Future<_ColumnData> loadColumn(UnifiedTradingBot bot) async {
        final accountId = bot.tradingbotId;
        final spec = (accountId: accountId, columnTitle: _columnTitle(bot));
        final pnl = await api.getDailyRealizedPnl(accountId, _year, _month);
        final snap = await api.getOpenPositionsSnapshots(accountId);
        final ap = byBot[accountId];
        final agg = _aggregateOpenPosSnapshots(snap.rows);
        var posErr = snap.success ? null : 'open-positions-snapshots 拉取失败';
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

      final cols = await Future.wait(sorted.map(loadColumn));

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

      setState(() {
        _columns = cols;
        _refPrice = refPx;
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

  String _monthTitle() => '$_year年$_month月';

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
              widget.embedInShell
                  ? 24 + AppFinanceStyle.webSummaryTitleSpacing
                  : 16,
              24,
              48,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1600),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    const SizedBox(height: 20),
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
                        padding: EdgeInsets.symmetric(
                          vertical: 48,
                          horizontal: 24,
                        ),
                        child: Center(
                          child: FinanceInlineLoadingBlock(
                            message: '正在加载各账户月度对比数据…',
                            subtitle: '请稍候，数据量较大时可能需要数秒',
                          ),
                        ),
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FinanceCard(
                            padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                            child: _ComparisonGrid(
                              dateCompact: _snapshotDateCompact(),
                              refPrice: _refPrice,
                              columns: _columns,
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
                                    '持仓快照提示',
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
    final titleStyle =
        (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
          color: AppFinanceStyle.labelColor,
          fontSize:
              (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 2,
          fontWeight: FontWeight.w600,
        );
    final monthNav = DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppFinanceStyle.cardBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left, size: 22),
            color: AppFinanceStyle.valueColor,
            tooltip: '上一月',
            visualDensity: VisualDensity.compact,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppFinanceStyle.valueColor,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right, size: 22),
            color: AppFinanceStyle.valueColor,
            tooltip: '下一月',
            visualDensity: VisualDensity.compact,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: TextButton(
              onPressed: onThisMonth,
              style: TextButton.styleFrom(
                foregroundColor: AppFinanceStyle.profitGreenEnd,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              child: const Text('本月'),
            ),
          ),
        ],
      ),
    );

    return FinanceCard(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 560;
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('账户绩效对比', style: titleStyle),
                const SizedBox(height: 6),
                Text(
                  '按月对比各账户持仓、成交与收益率',
                  style: AppFinanceStyle.labelTextStyle(context).copyWith(
                    fontSize: 13,
                    color: AppFinanceStyle.textDefault.withValues(alpha: 0.55),
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 14),
                Center(child: monthNav),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('账户绩效对比', style: titleStyle),
                    const SizedBox(height: 6),
                    Text(
                      '按月对比各账户持仓、成交与收益率',
                      style: AppFinanceStyle.labelTextStyle(context).copyWith(
                        fontSize: 13,
                        color: AppFinanceStyle.textDefault.withValues(alpha: 0.55),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              monthNav,
            ],
          );
        },
      ),
    );
  }
}

/// 账户级汇总：取 [rows] 中最新一批 snapshot_at 的各行（按合约），
/// 成本线为库中 long_avg_px / short_avg_px 的加权平均。
_PosAgg _aggregateOpenPosSnapshots(List<OpenPositionsSnapshotRow> rows) {
  if (rows.isEmpty) {
    return _PosAgg(
      longQty: 0,
      shortQty: 0,
      longAvgPx: 0,
      shortAvgPx: 0,
      totalUpl: 0,
      refMarkPx: null,
    );
  }
  final latest = rows.first.snapshotAt;
  final batch = rows.where((r) => r.snapshotAt == latest).toList();
  var lq = 0.0;
  var sq = 0.0;
  var lNotional = 0.0;
  var sNotional = 0.0;
  var uplSum = 0.0;
  double? refPx;
  for (final r in batch) {
    lq += r.longPosSize;
    sq += r.shortPosSize;
    lNotional += r.longPosSize * r.longAvgPx;
    sNotional += r.shortPosSize * r.shortAvgPx;
    uplSum += r.totalUpl;
    final px = r.lastPx > 0 ? r.lastPx : r.markPx;
    if (px > 0) {
      final prev = refPx;
      refPx = prev == null ? px : math.max(prev, px);
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

  /// 多-成本线 − 空-成本线
  double get costGap =>
      longAvgPx > 0 && shortAvgPx > 0 ? longAvgPx - shortAvgPx : double.nan;
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

  final ({String accountId, String columnTitle}) spec;
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

  String _fmtGap(double v) {
    if (!v.isFinite) return '—';
    return v.round().toString();
  }

  /// 成本线数值过小，×1e9 后取整便于对比。
  String _fmtCostLine1e9(double v) {
    if (!v.isFinite || v <= 0) return '—';
    return (v * 1e9).round().toString();
  }

  String _fmtCostGap1e9(double g) {
    if (!g.isFinite) return '—';
    return (g * 1e9).round().toString();
  }

  String get _floatRow =>
      agg == null ? '—' : formatUiSignedUsdt2(agg!.totalUpl);
}

class _ComparisonGrid extends StatelessWidget {
  const _ComparisonGrid({
    required this.dateCompact,
    required this.refPrice,
    required this.columns,
    required this.year,
    required this.month,
  });

  final String dateCompact;
  final double? refPrice;
  final List<_ColumnData> columns;
  final int year;
  final int month;

  static const Color _gridColor = AppFinanceStyle.webDataGridLine;
  /// 左侧指标列底色
  static const Color _labelColumnBg = AppFinanceStyle.webDataTableLabelBg;
  /// 右侧账号数据区底色
  static const Color _accountColumnBg = AppFinanceStyle.webDataTableCellBg;
  static const double _labelW = 168.0;
  static const double _minDataColW = 72.0;

  @override
  Widget build(BuildContext context) {
    final baseStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontSize: 14,
      color: AppFinanceStyle.valueColor,
      height: 1.35,
    );
    // 左侧「指标」列：粗体、右对齐、字号比数据格再大一号
    final metricLabelStyle = baseStyle?.copyWith(
      color: AppFinanceStyle.labelColor,
      fontWeight: FontWeight.w700,
      fontSize: 15,
    );

    final priceText = refPrice != null && refPrice! > 0
        ? (refPrice! * 1e9).round().toString()
        : '—';

    final n = columns.length;
    if (n == 0) {
      return Text('无列', style: AppFinanceStyle.labelTextStyle(context));
    }

    final metricSpecs =
        <({String label, String Function(_ColumnData c) value, bool bold})>[
          (
            label: '多-数量',
            value: (c) => c.agg == null ? '—' : c._fmtQty(c.agg!.longQty),
            bold: false,
          ),
          (
            label: '多-成本',
            value: (c) => c.agg == null ? '—' : c._fmtCostLine1e9(c.agg!.longAvgPx),
            bold: false,
          ),
          (
            label: '空-数量',
            value: (c) => c.agg == null ? '—' : c._fmtQty(c.agg!.shortQty),
            bold: false,
          ),
          (
            label: '空-成本',
            value: (c) => c.agg == null ? '—' : c._fmtCostLine1e9(c.agg!.shortAvgPx),
            bold: false,
          ),
          (
            label: '数量差',
            value: (c) => c.agg == null ? '—' : c._fmtGap(c.agg!.qtyGap),
            bold: false,
          ),
          (
            label: '成本差',
            value: (c) =>
                c._fmtCostGap1e9(c.agg?.costGap ?? double.nan),
            bold: false,
          ),
          (
            label: '资产余额',
            value: (c) => formatUiIntegerOpt(
              c.profit?.cashBalance ?? c.profit?.balanceUsdt,
            ),
            bold: false,
          ),
          (label: '浮动盈亏', value: (c) => c._floatRow, bold: false),
          (
            label: '权益金额',
            value: (c) => formatUiIntegerOpt(c.profit?.equityUsdt),
            bold: false,
          ),
          (
            label: '成交次数($month月)',
            value: (c) => c.monthCloseCount.toString(),
            bold: false,
          ),
          (
            label: '成交金额-($month月)',
            value: (c) => formatUiSignedUsdt2(c.monthPnl),
            bold: false,
          ),
          (
            label: '收益率-($month月)',
            value: (c) => formatUiPercentLabel(c.monthReturnPct),
            bold: true,
          ),
        ];

    Widget gridAtWidth(double tableWidth) {
      final dataBlockWidth = math.max(tableWidth - _labelW, n * _minDataColW);
      return Container(
        width: tableWidth,
        decoration: BoxDecoration(
          border: Border.all(color: _gridColor, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: _labelW,
                    child: _cellBorder(
                      right: true,
                      bottom: true,
                      fillColor: _labelColumnBg,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            dateCompact,
                            textAlign: TextAlign.right,
                            style: metricLabelStyle?.copyWith(
                              color: AppFinanceStyle.valueColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: dataBlockWidth,
                    child: _cellBorder(
                      right: false,
                      bottom: true,
                      fillColor: _accountColumnBg,
                      child: Center(
                        child: Text(
                          '当前价格　$priceText',
                          style: baseStyle?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _tableRow(
              dataBlockWidth: dataBlockWidth,
              n: n,
              labelChild: Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    '指标',
                    textAlign: TextAlign.right,
                    style: metricLabelStyle,
                  ),
                ),
              ),
              dataChildren: (i) => Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 4,
                ),
                child: Text(
                  columns[i].spec.columnTitle,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: baseStyle?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            _tableRow(
              dataBlockWidth: dataBlockWidth,
              n: n,
              labelChild: Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    '基数',
                    textAlign: TextAlign.right,
                    style: metricLabelStyle,
                  ),
                ),
              ),
              dataChildren: (i) => Text(
                formatUiIntegerOpt(columns[i].profit?.initialBalance),
                textAlign: TextAlign.center,
                style: baseStyle,
              ),
            ),
            ...metricSpecs.map(
              (spec) => _tableRow(
                dataBlockWidth: dataBlockWidth,
                n: n,
                labelChild: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      spec.label,
                      textAlign: TextAlign.right,
                      style: metricLabelStyle,
                    ),
                  ),
                ),
                dataChildren: (i) {
                  final c = columns[i];
                  final t = spec.value(c);
                  return Text(
                    t,
                    textAlign: TextAlign.center,
                    style: spec.bold
                        ? baseStyle?.copyWith(fontWeight: FontWeight.w800)
                        : baseStyle,
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final minTable = _labelW + n * _minDataColW;
        final w = math.max(constraints.maxWidth, minTable);
        final scroll = constraints.maxWidth < minTable - 1;
        final child = gridAtWidth(w);
        if (!scroll) return child;
        return Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: child,
          ),
        );
      },
    );
  }

  Widget _tableRow({
    required double dataBlockWidth,
    required int n,
    required Widget labelChild,
    required Widget Function(int index) dataChildren,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _labelW,
            child: _cellBorder(
              right: true,
              bottom: true,
              fillColor: _labelColumnBg,
              child: labelChild,
            ),
          ),
          SizedBox(
            width: dataBlockWidth,
            child: Row(
              children: List.generate(
                n,
                (i) => Expanded(
                  child: _cellBorder(
                    right: i < n - 1,
                    bottom: true,
                    fillColor: _accountColumnBg,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 4,
                      ),
                      child: Align(
                        alignment: Alignment.center,
                        child: dataChildren(i),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cellBorder({
    required bool right,
    required bool bottom,
    Color? fillColor,
    required Widget child,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fillColor,
        border: Border(
          right: right
              ? BorderSide(color: _gridColor, width: 1)
              : BorderSide.none,
          bottom: BorderSide(color: _gridColor, width: 1),
        ),
      ),
      child: child,
    );
  }
}
