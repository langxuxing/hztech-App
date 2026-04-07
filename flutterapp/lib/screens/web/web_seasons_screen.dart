import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../utils/beijing_format.dart';
import '../../utils/number_display_format.dart';
import '../../widgets/water_background.dart';

/// 按账户展示赛季列表（与策略启停赛季操作联动）；
/// 结合历史仓位统计每赛季笔数与盈亏：时刻取 OKX uTime（与接口一致，非开仓 cTime）。
class WebSeasonsScreen extends StatefulWidget {
  const WebSeasonsScreen({
    super.key,
    this.sharedBots = const [],
    this.embedInShell = false,
    this.accountIdFromParent,
    this.marketSymbol,
  });

  final List<UnifiedTradingBot> sharedBots;
  final bool embedInShell;

  /// 非空时由上层（如赛季/历史仓位 Hub）统一选账户，本页不显示账户下拉。
  final String? accountIdFromParent;

  /// 交易对展示（可由 Hub 传入，否则从 [sharedBots] 匹配）。
  final String? marketSymbol;

  @override
  State<WebSeasonsScreen> createState() => _WebSeasonsScreenState();
}

class _SeasonAgg {
  _SeasonAgg({
    required this.count,
    required this.profitSum,
    required this.rows,
  });

  final int count;
  final double profitSum;
  final List<PositionHistoryRow> rows;
}

class _WebSeasonsScreenState extends State<WebSeasonsScreen> {
  final _prefs = SecurePrefs();
  String? _botId;
  List<BotSeason> _seasons = [];
  List<PositionHistoryRow> _history = [];
  int? _activeCount;
  bool _loading = false;
  String? _error;

  /// 无服务端赛季记录时，为 true：按北京时间自然周汇总 [_history]。
  bool _weeklyFallback = false;

  List<UnifiedTradingBot> get _bots => widget.sharedBots;

  String? get _effectiveBotId => widget.accountIdFromParent ?? _botId;

  String? get _marketLabel {
    final m = widget.marketSymbol;
    if (m != null && m.isNotEmpty) return m;
    final id = _effectiveBotId;
    if (id == null) return null;
    for (final b in _bots) {
      if (b.tradingbotId == id) {
        final s = b.symbol;
        if (s != null && s.isNotEmpty) return s;
      }
    }
    return null;
  }

  static DateTime? _parseIsoUtc(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final dt = DateTime.parse(s.trim());
      return dt.isUtc ? dt : dt.toUtc();
    } catch (_) {
      return null;
    }
  }

  /// OKX positions-history 的 uTime（仓位更新时间），平仓记录上即平仓相关时刻。
  static DateTime? _rowCloseUtc(PositionHistoryRow r) {
    final ms = r.uTimeMs;
    if (ms == null || ms.isEmpty) return null;
    final v = int.tryParse(ms.trim());
    if (v == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
  }

  static double? _rowPnl(PositionHistoryRow r) {
    final raw = r.realizedPnl ?? r.pnl;
    if (raw == null || raw.isEmpty) return null;
    return double.tryParse(raw.trim());
  }

  static bool _positionInSeason(
    PositionHistoryRow r,
    DateTime startUtc,
    DateTime? endUtc,
  ) {
    final ut = _rowCloseUtc(r);
    if (ut == null) return false;
    if (ut.isBefore(startUtc)) return false;
    final endBound = endUtc ?? DateTime.now().toUtc();
    if (ut.isAfter(endBound)) return false;
    return true;
  }

  /// 平仓时刻对应的北京日历日（UTC DateTime 仅作 y/m/d 容器）。
  static DateTime _beijingCalendarDateUtc(DateTime utc) {
    final b = utc.add(const Duration(hours: 8));
    return DateTime.utc(b.year, b.month, b.day);
  }

  static DateTime _mondayOfBeijingWeekContaining(DateTime beijingCalDateUtc) {
    final wd = beijingCalDateUtc.weekday;
    return beijingCalDateUtc.subtract(Duration(days: wd - 1));
  }

  /// 北京周一 00:00 对应的 UTC 时刻（区间起点，含）。
  static DateTime _beijingMondayStartUtc(DateTime mondayCalUtc) {
    return DateTime.utc(
      mondayCalUtc.year,
      mondayCalUtc.month,
      mondayCalUtc.day,
    ).subtract(const Duration(hours: 8));
  }

  /// 下周一北京 00:00 对应的 UTC（区间终点，不含）。
  static DateTime _nextBeijingMondayStartUtc(DateTime mondayCalUtc) {
    final next = mondayCalUtc.add(const Duration(days: 7));
    return DateTime.utc(
      next.year,
      next.month,
      next.day,
    ).subtract(const Duration(hours: 8));
  }

  static bool _positionInBeijingWeek(
    PositionHistoryRow r,
    DateTime mondayCalUtc,
  ) {
    final ut = _rowCloseUtc(r);
    if (ut == null) return false;
    final start = _beijingMondayStartUtc(mondayCalUtc);
    final endEx = _nextBeijingMondayStartUtc(mondayCalUtc);
    if (ut.isBefore(start)) return false;
    if (!ut.isBefore(endEx)) return false;
    return true;
  }

  static String _beijingWeekRangeLabel(DateTime mondayCalUtc) {
    final end = mondayCalUtc.add(const Duration(days: 6));
    String p2(int x) => x.toString().padLeft(2, '0');
    return '${mondayCalUtc.year}-${p2(mondayCalUtc.month)}-${p2(mondayCalUtc.day)}'
        ' ~ ${end.year}-${p2(end.month)}-${p2(end.day)}';
  }

  static bool _isCurrentBeijingWeekMonday(DateTime mondayCalUtc) {
    final now = DateTime.now().toUtc();
    final bd = _beijingCalendarDateUtc(now);
    final thisMon = _mondayOfBeijingWeekContaining(bd);
    return mondayCalUtc.year == thisMon.year &&
        mondayCalUtc.month == thisMon.month &&
        mondayCalUtc.day == thisMon.day;
  }

  _SeasonAgg _aggForBeijingWeek(DateTime mondayCalUtc) {
    final rows =
        _history.where((r) => _positionInBeijingWeek(r, mondayCalUtc)).toList();
    double sum = 0;
    for (final r in rows) {
      final p = _rowPnl(r);
      if (p != null && p.isFinite) sum += p;
    }
    return _SeasonAgg(count: rows.length, profitSum: sum, rows: rows);
  }

  List<DateTime> _beijingWeekMondaysDescending() {
    final keys = <DateTime>{};
    for (final r in _history) {
      final ut = _rowCloseUtc(r);
      if (ut == null) continue;
      final bd = _beijingCalendarDateUtc(ut);
      keys.add(_mondayOfBeijingWeekContaining(bd));
    }
    final list = keys.toList()
      ..sort((a, b) => b.compareTo(a));
    return list;
  }

  _SeasonAgg _aggForSeason(BotSeason s) {
    final st = _parseIsoUtc(s.startedAt);
    if (st == null) {
      return _SeasonAgg(count: 0, profitSum: 0, rows: []);
    }
    final en = s.isActive == true ? null : _parseIsoUtc(s.stoppedAt);
    final rows = _history.where((r) => _positionInSeason(r, st, en)).toList();
    double sum = 0;
    for (final r in rows) {
      final p = _rowPnl(r);
      if (p != null && p.isFinite) sum += p;
    }
    return _SeasonAgg(count: rows.length, profitSum: sum, rows: rows);
  }

  DateTime? _oldestSeasonStartUtc(List<BotSeason> seasons) {
    DateTime? minDt;
    for (final s in seasons) {
      final t = _parseIsoUtc(s.startedAt);
      if (t == null) continue;
      if (minDt == null || t.isBefore(minDt)) minDt = t;
    }
    return minDt;
  }

  Future<List<PositionHistoryRow>> _loadHistoryForStats(
    ApiClient api,
    String bid,
    DateTime minCloseUtc,
  ) async {
    final out = <PositionHistoryRow>[];
    int? before;
    const limit = 500;
    for (var i = 0; i < 20; i++) {
      final resp = await api.getPositionHistory(
        bid,
        limit: limit,
        beforeUtime: before,
      );
      if (!resp.success || resp.rows.isEmpty) break;
      out.addAll(resp.rows);
      final lastUt = _rowCloseUtc(resp.rows.last);
      if (lastUt != null && lastUt.isBefore(minCloseUtc)) break;
      before = resp.nextBeforeUtime;
      if (before == null) break;
    }
    return out;
  }

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
      final seasons = resp.seasons;
      List<PositionHistoryRow> hist = [];
      final oldest = _oldestSeasonStartUtc(seasons);
      final weeklyFallback = seasons.isEmpty;
      if (weeklyFallback) {
        hist = await _loadHistoryForStats(
          api,
          bid,
          DateTime.now().toUtc().subtract(const Duration(days: 730)),
        );
      } else if (oldest != null) {
        hist = await _loadHistoryForStats(api, bid, oldest);
      }
      if (!mounted) return;
      setState(() {
        _seasons = seasons;
        _activeCount = resp.activeSeasonCount;
        _history = hist;
        _weeklyFallback = weeklyFallback;
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

  TextStyle _label(BuildContext context, {double fs = 12}) =>
      AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: fs);

  TextStyle _value(BuildContext context, {double fs = 13}) =>
      TextStyle(color: AppFinanceStyle.valueColor, fontSize: fs);

  Widget _metricChip(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 14, bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: _label(context, fs: 12)),
          const SizedBox(width: 4),
          Text(
            value,
            style: _value(context, fs: 13).copyWith(
              color: valueColor ?? AppFinanceStyle.valueColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _wrapRow(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      ),
    );
  }

  Widget _miniPositionRow(PositionHistoryRow r) {
    final pnlRaw = r.realizedPnl ?? r.pnl;
    final pnl = double.tryParse((pnlRaw ?? '').trim());
    final pnlColor = pnl == null
        ? null
        : (pnl > 0
              ? AppFinanceStyle.profitGreenEnd
              : (pnl < 0 ? AppFinanceStyle.textLoss : null));
    final side = (r.posSide ?? '').toLowerCase();
    final sideLabel = side == 'long'
        ? '多'
        : side == 'short'
        ? '空'
        : (r.posSide ?? '—');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              r.instId ?? '—',
              style: TextStyle(color: AppFinanceStyle.valueColor, fontSize: 12),
            ),
          ),
          SizedBox(
            width: 28,
            child: Text(
              sideLabel,
              style: TextStyle(color: AppFinanceStyle.labelColor, fontSize: 12),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              pnlRaw == null || pnlRaw.isEmpty
                  ? '—'
                  : double.tryParse(pnlRaw)?.toStringAsFixed(1) ?? pnlRaw,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: pnlColor ?? AppFinanceStyle.valueColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              formatEpochMsAsBeijing(r.uTimeMs),
              textAlign: TextAlign.end,
              style: TextStyle(color: AppFinanceStyle.labelColor, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _positionsExpansion(
    BuildContext context,
    String title,
    _SeasonAgg agg,
  ) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        initiallyExpanded: false,
        title: Text(
          title,
          style: _label(context, fs: 13).copyWith(
            color: AppFinanceStyle.valueColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: [
          if (agg.rows.isEmpty)
            Text(
              '无匹配平仓记录（按 OKX uTime 对应北京时间落在区间内）',
              style: _label(context, fs: 12),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text('标的', style: _label(context, fs: 11)),
                ),
                SizedBox(
                  width: 28,
                  child: Text('向', style: _label(context, fs: 11)),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '盈亏',
                    textAlign: TextAlign.end,
                    style: _label(context, fs: 11),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Text(
                    '平仓时间(北京)',
                    textAlign: TextAlign.end,
                    style: _label(context, fs: 11),
                  ),
                ),
              ],
            ),
            const Divider(height: 1, color: Color(0x33FFFFFF)),
            ...agg.rows.map(_miniPositionRow),
          ],
        ],
      ),
    );
  }

  /// 进行中优先；否则列表首条为「最近赛季」。
  BotSeason? _highlightSeason() {
    for (final s in _seasons) {
      if (s.isActive == true) return s;
    }
    if (_seasons.isNotEmpty) return _seasons.first;
    return null;
  }

  List<BotSeason> _otherSeasons(BotSeason? highlight) {
    if (highlight == null) return _seasons;
    return _seasons.where((s) => s.id != highlight.id).toList();
  }

  Widget _buildHighlightCard(
    BuildContext context,
    BotSeason s,
    _SeasonAgg agg,
  ) {
    final active = s.isActive == true;
    final mkt = _marketLabel ?? '—';
    final profitColor = (s.profitAmount ?? 0) >= 0
        ? AppFinanceStyle.profitGreenEnd
        : AppFinanceStyle.textLoss;

    final metricsColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _wrapRow([_metricChip(context, '交易标的：', mkt)]),
        const SizedBox(height: 10),
        _wrapRow([
          _metricChip(context, '开始时间(北京):', formatIsoAsBeijing(s.startedAt)),
          const SizedBox(width: 10),
          _metricChip(context, '结束时间(北京):', formatIsoAsBeijing(s.stoppedAt)),
          const SizedBox(width: 10),
        ]),
        _wrapRow([
          _metricChip(context, '开始资金：', formatUiInteger(s.initialBalance)),
          const SizedBox(width: 10),
          if (s.finalBalance != null)
            _metricChip(context, '结束资金：', formatUiInteger(s.finalBalance!)),
          const SizedBox(width: 10),
          if (s.profitAmount != null)
            _metricChip(
              context,
              '盈利：',
              s.profitAmount!.toStringAsFixed(1),
              valueColor: profitColor,
            ),
          const SizedBox(width: 10),
          if (s.profitPercent != null)
            _metricChip(
              context,
              '收益率：',
              formatUiPercentLabel(s.profitPercent!),
              valueColor: profitColor,
            ),
        ]),
        _wrapRow([
          _metricChip(context, 'ATR(14天):', '—'),
          const SizedBox(width: 10),
          _metricChip(context, '多空获利止盈距离:', '—'),
          const SizedBox(width: 10),
          _metricChip(context, '第一次浮亏加仓距离:', '—'),
          const SizedBox(width: 10),
          _metricChip(context, '第二次浮亏加仓距离:', '—'),
        ]),
      ],
    );
    final historyExpansion = _positionsExpansion(
      context,
      '本赛季历史仓位（${agg.count}）',
      agg,
    );

    return FinanceCard(
      padding: const EdgeInsets.all(20),
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
                    color: AppFinanceStyle.profitGreenEnd.withValues(
                      alpha: 0.2,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '进行中',
                    style: TextStyle(
                      color: AppFinanceStyle.profitGreenEnd,
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
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '最近赛季',
                    style: TextStyle(
                      color: AppFinanceStyle.labelColor,
                      fontSize: 12,
                    ),
                  ),
                ),
              const Spacer(),
              Text('#${s.id}', style: _label(context, fs: 12)),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (ctx, bc) {
              final wide = bc.maxWidth >= 520;
              if (!wide) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    metricsColumn,
                    historyExpansion,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: metricsColumn,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 5,
                    child: historyExpansion,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPastCard(BuildContext context, BotSeason s) {
    final active = s.isActive == true;
    final agg = _aggForSeason(s);
    final profitColor = agg.profitSum >= 0
        ? AppFinanceStyle.profitGreenEnd
        : AppFinanceStyle.textLoss;

    final metricsColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _wrapRow([
          _metricChip(context, '开始', formatIsoAsBeijing(s.startedAt)),
          _metricChip(context, '结束', formatIsoAsBeijing(s.stoppedAt)),
          _metricChip(context, '市场', _marketLabel ?? '—'),
        ]),
        _wrapRow([
          _metricChip(context, '初期', formatUiInteger(s.initialBalance)),
          if (s.finalBalance != null)
            _metricChip(context, '期末', formatUiInteger(s.finalBalance!)),
          if (s.profitAmount != null)
            _metricChip(
              context,
              '盈利',
              s.profitAmount!.toStringAsFixed(1),
              valueColor: (s.profitAmount ?? 0) >= 0
                  ? AppFinanceStyle.profitGreenEnd
                  : AppFinanceStyle.textLoss,
            ),
          if (s.profitPercent != null)
            _metricChip(
              context,
              '收益率',
              formatUiPercentLabel(s.profitPercent!),
            ),
        ]),
        _wrapRow([
          _metricChip(
            context,
            '仓位数·盈亏',
            '${agg.count} · ${agg.profitSum.toStringAsFixed(1)}',
            valueColor: profitColor,
          ),
        ]),
      ],
    );
    final historyExpansion = _positionsExpansion(
      context,
      '历史仓位（${agg.count}）',
      agg,
    );

    return FinanceCard(
      padding: const EdgeInsets.all(20),
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
                    color: AppFinanceStyle.profitGreenEnd.withValues(
                      alpha: 0.2,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '进行中',
                    style: TextStyle(
                      color: AppFinanceStyle.profitGreenEnd,
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
                    borderRadius: BorderRadius.circular(6),
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
              Text('#${s.id}', style: _label(context, fs: 12)),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (ctx, bc) {
              final wide = bc.maxWidth >= 520;
              if (!wide) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    metricsColumn,
                    historyExpansion,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: metricsColumn,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 5,
                    child: historyExpansion,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildWeeklyCard(
    BuildContext context,
    DateTime mondayCalUtc,
    _SeasonAgg agg, {
    required bool highlight,
    required bool currentWeek,
  }) {
    final profitColor = agg.profitSum >= 0
        ? AppFinanceStyle.profitGreenEnd
        : AppFinanceStyle.textLoss;
    final range = _beijingWeekRangeLabel(mondayCalUtc);

    final metricsColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _wrapRow([
          _metricChip(context, '自然周', range),
          _metricChip(context, '市场', _marketLabel ?? '—'),
        ]),
        _wrapRow([
          _metricChip(
            context,
            '仓位数·盈亏',
            '${agg.count} · ${agg.profitSum.toStringAsFixed(1)}',
            valueColor: profitColor,
          ),
        ]),
      ],
    );
    final historyExpansion = _positionsExpansion(
      context,
      '本周历史仓位（${agg.count}）',
      agg,
    );

    return FinanceCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (highlight && currentWeek)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppFinanceStyle.profitGreenEnd.withValues(
                      alpha: 0.2,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '当前周',
                    style: TextStyle(
                      color: AppFinanceStyle.profitGreenEnd,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else if (highlight)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '最近一周',
                    style: TextStyle(
                      color: AppFinanceStyle.labelColor,
                      fontSize: 12,
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
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '自然周',
                    style: TextStyle(
                      color: AppFinanceStyle.labelColor,
                      fontSize: 12,
                    ),
                  ),
                ),
              const Spacer(),
              Text(
                mondayCalUtc.toIso8601String().split('T').first,
                style: _label(context, fs: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (ctx, bc) {
              final wide = bc.maxWidth >= 520;
              if (!wide) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    metricsColumn,
                    historyExpansion,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: metricsColumn,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 5,
                    child: historyExpansion,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final column = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.accountIdFromParent == null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                widget.embedInShell ? 12 : 24 + AppFinanceStyle.webSummaryTitleSpacing,
                24,
                12,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: (MediaQuery.sizeOf(context).width * 0.5)
                        .clamp(200.0, 360.0),
                  ),
                  child: FinanceCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: DropdownButtonFormField<String>(
                      value: _botId != null &&
                              _bots.any((b) => b.tradingbotId == _botId)
                          ? _botId
                          : null,
                      decoration: InputDecoration(
                        labelText: '账户',
                        labelStyle: AppFinanceStyle.labelTextStyle(context),
                        border: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                      ),
                      dropdownColor: AppFinanceStyle.cardBackground
                          .withValues(alpha: 0.98),
                      style: const TextStyle(
                        color: AppFinanceStyle.valueColor,
                        fontSize:
                            AppFinanceStyle.webAccountProfitBotDropdownFontSize,
                        fontWeight: FontWeight.w500,
                      ),
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
                ),
              ),
            )
          else
            const SizedBox(height: 8),
          if (_activeCount != null && _activeCount! > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Text(
                '进行中赛季数：$_activeCount（请在「策略启停」使用赛季开始/停止）',
                style: AppFinanceStyle.labelTextStyle(
                  context,
                ).copyWith(fontSize: 13, color: AppFinanceStyle.profitGreenEnd),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                style: TextStyle(color: AppFinanceStyle.textLoss, fontSize: 13),
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
                : Builder(
                    builder: (ctx) {
                      if (_weeklyFallback && _seasons.isEmpty) {
                        final weeks = _beijingWeekMondaysDescending();
                        final hi = weeks.isNotEmpty ? weeks.first : null;
                        final others =
                            weeks.length > 1 ? weeks.sublist(1) : <DateTime>[];
                        final hiCurrent =
                            hi != null &&
                            _isCurrentBeijingWeekMonday(hi);
                        return ListView(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Text(
                                '当前账户未配置赛季，已按北京时间自然周（周一至周日）汇总最近约 2 年的平仓；'
                                '在「策略启停」使用赛季开始/停止后可改为正式赛季统计。',
                                style: AppFinanceStyle.labelTextStyle(context)
                                    .copyWith(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: AppFinanceStyle.textDefault
                                      .withValues(alpha: 0.58),
                                ),
                              ),
                            ),
                            if (hi == null)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 24),
                                child: Text(
                                  '暂无历史平仓记录，无法按周汇总',
                                  style:
                                      AppFinanceStyle.labelTextStyle(context),
                                ),
                              )
                            else ...[
                              Text(
                                hiCurrent ? '当前自然周' : '最近自然周',
                                style: AppFinanceStyle.labelTextStyle(context)
                                    .copyWith(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppFinanceStyle.labelColor,
                                  letterSpacing: 0.35,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _buildWeeklyCard(
                                ctx,
                                hi,
                                _aggForBeijingWeek(hi),
                                highlight: true,
                                currentWeek: hiCurrent,
                              ),
                              const SizedBox(height: 16),
                              if (others.isNotEmpty) ...[
                                Text(
                                  '更早自然周',
                                  style: AppFinanceStyle.labelTextStyle(context)
                                      .copyWith(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: AppFinanceStyle.labelColor,
                                    letterSpacing: 0.35,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ...others.map((mon) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: _buildWeeklyCard(
                                      ctx,
                                      mon,
                                      _aggForBeijingWeek(mon),
                                      highlight: false,
                                      currentWeek: false,
                                    ),
                                  );
                                }),
                              ],
                            ],
                          ],
                        );
                      }

                      final hi = _highlightSeason();
                      final others = _otherSeasons(hi);
                      return ListView(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                        children: [
                          if (_seasons.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              child: Text(
                                '暂无赛季记录',
                                style: AppFinanceStyle.labelTextStyle(context),
                              ),
                            )
                          else ...[
                            if (hi != null) ...[
                              Text(
                                hi.isActive == true ? '当前赛季' : '最近赛季',
                                style: AppFinanceStyle.labelTextStyle(context)
                                    .copyWith(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppFinanceStyle.labelColor,
                                  letterSpacing: 0.35,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _buildHighlightCard(ctx, hi, _aggForSeason(hi)),
                              const SizedBox(height: 16),
                            ],
                            if (others.isNotEmpty) ...[
                              Text(
                                '历史赛季',
                                style: AppFinanceStyle.labelTextStyle(context)
                                    .copyWith(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppFinanceStyle.labelColor,
                                  letterSpacing: 0.35,
                                ),
                              ),
                              const SizedBox(height: 8),
                              ...others.map((s) {
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _buildPastCard(ctx, s),
                                );
                              }),
                            ],
                          ],
                        ],
                      );
                    },
                  ),
          ),
        ],
      );
    final bounded = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: column,
      ),
    );
    final content = widget.accountIdFromParent != null
        ? bounded
        : WaterBackground(child: bounded);

    if (widget.embedInShell) {
      return content;
    }
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '赛季',
          style: AppFinanceStyle.labelTextStyle(
            context,
          ).copyWith(color: AppFinanceStyle.valueColor, fontSize: 18),
        ),
        backgroundColor: AppFinanceStyle.backgroundDark,
        foregroundColor: AppFinanceStyle.valueColor,
        surfaceTintColor: Colors.transparent,
      ),
      body: content,
    );
  }
}
