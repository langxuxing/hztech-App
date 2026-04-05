import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../utils/beijing_format.dart';
import '../../utils/number_display_format.dart';
import '../../widgets/water_background.dart';

/// 按账户展示赛季列表（与策略启停赛季操作联动）；
/// 结合历史仓位平仓时间统计每赛季笔数与盈亏（分页拉取直至覆盖最早赛季起点）。
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

  List<UnifiedTradingBot> get _bots => widget.sharedBots;

  String? get _effectiveBotId =>
      widget.accountIdFromParent ?? _botId;

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

  _SeasonAgg _aggForSeason(BotSeason s) {
    final st = _parseIsoUtc(s.startedAt);
    if (st == null) {
      return _SeasonAgg(count: 0, profitSum: 0, rows: []);
    }
    final en = s.isActive == true ? null : _parseIsoUtc(s.stoppedAt);
    final rows = _history
        .where((r) => _positionInSeason(r, st, en))
        .toList();
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
      if (oldest != null) {
        hist = await _loadHistoryForStats(api, bid, oldest);
      }
      if (!mounted) return;
      setState(() {
        _seasons = seasons;
        _activeCount = resp.activeSeasonCount;
        _history = hist;
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

  TextStyle _value(BuildContext context, {double fs = 13}) => TextStyle(
        color: AppFinanceStyle.valueColor,
        fontSize: fs,
      );

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
            : (pnl < 0 ? const Color(0xFFFF6B6B) : null));
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
              '本赛季无匹配平仓记录（按更新时间在北京时间落在赛季区间内）',
              style: _label(context, fs: 12),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text('标的', style: _label(context, fs: 11)),
                ),
                SizedBox(width: 28, child: Text('向', style: _label(context, fs: 11))),
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
                    '更新(北京)',
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

  Widget _buildHighlightCard(BuildContext context, BotSeason s, _SeasonAgg agg) {
    final active = s.isActive == true;
    final mkt = _marketLabel ?? '—';
    final profitColor = (s.profitAmount ?? 0) >= 0
        ? AppFinanceStyle.profitGreenEnd
        : Colors.red.shade300;

    return FinanceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (active)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.2),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              Text(
                '#${s.id}',
                style: _label(context, fs: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _wrapRow([
            _metricChip(
              context,
              '开始(北京)',
              formatIsoAsBeijing(s.startedAt),
            ),
            _metricChip(
              context,
              '结束(北京)',
              formatIsoAsBeijing(s.stoppedAt),
            ),
            _metricChip(context, '市场', mkt),
          ]),
          _wrapRow([
            _metricChip(
              context,
              '初期',
              formatUiInteger(s.initialBalance),
            ),
            if (s.finalBalance != null)
              _metricChip(
                context,
                '期末',
                formatUiInteger(s.finalBalance!),
              ),
            if (s.profitAmount != null)
              _metricChip(
                context,
                '盈利',
                s.profitAmount!.toStringAsFixed(1),
                valueColor: profitColor,
              ),
            if (s.profitPercent != null)
              _metricChip(
                context,
                '收益率',
                formatUiPercentLabel(s.profitPercent!),
                valueColor: profitColor,
              ),
          ]),
          _wrapRow([
            _metricChip(context, 'ATR', '—'),
          ]),
          _wrapRow([
            _metricChip(context, '基于ATR·获利', '—'),
            _metricChip(context, '一加仓', '—'),
            _metricChip(context, '二加仓', '—'),
          ]),
          _wrapRow([
            _metricChip(
              context,
              '历史仓位数',
              '${agg.count}（赛季内平仓，盈亏合计 ${agg.profitSum.toStringAsFixed(1)}）',
            ),
          ]),
          _positionsExpansion(
            context,
            '本赛季历史仓位（${agg.count}）',
            agg,
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
        : const Color(0xFFFF6B6B);

    return FinanceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (active)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.2),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
          const SizedBox(height: 8),
          _wrapRow([
            _metricChip(
              context,
              '开始',
              formatIsoAsBeijing(s.startedAt),
            ),
            _metricChip(
              context,
              '结束',
              formatIsoAsBeijing(s.stoppedAt),
            ),
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
                    : Colors.red.shade300,
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
          _positionsExpansion(
            context,
            '历史仓位（${agg.count}）',
            agg,
          ),
        ],
      ),
    );
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
                    : Builder(
                        builder: (ctx) {
                          final hi = _highlightSeason();
                          final others = _otherSeasons(hi);
                          return ListView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            children: [
                              if (_seasons.isEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 24),
                                  child: Text(
                                    '暂无赛季记录',
                                    style:
                                        AppFinanceStyle.labelTextStyle(context),
                                  ),
                                )
                              else ...[
                                if (hi != null) ...[
                                  Text(
                                    hi.isActive == true ? '当前赛季' : '最近赛季',
                                    style: AppFinanceStyle.labelTextStyle(
                                      context,
                                    ).copyWith(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: AppFinanceStyle.valueColor,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _buildHighlightCard(
                                    ctx,
                                    hi,
                                    _aggForSeason(hi),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                if (others.isNotEmpty) ...[
                                  Text(
                                    '历史赛季',
                                    style: AppFinanceStyle.labelTextStyle(
                                      context,
                                    ).copyWith(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: AppFinanceStyle.valueColor,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ...others.map((s) {
                                    return Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 10),
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
}
