import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/strategy_efficiency_lightweight_chart.dart';
import '../../widgets/water_background.dart';

enum _EffBarHatchPattern { diagonal, grid }

class _EffBarPatternLegendPainter extends CustomPainter {
  const _EffBarPatternLegendPainter({
    required this.pattern,
    required this.baseColor,
  });

  final _EffBarHatchPattern pattern;
  final Color baseColor;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(2),
    );
    canvas.drawRRect(r, Paint()..color = baseColor);
    canvas.save();
    canvas.clipRRect(r);
    final w = size.width;
    final h = size.height;
    if (pattern == _EffBarHatchPattern.grid) {
      final g1 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.4);
      final g2 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.22);
      for (var g = 0.0; g <= w; g += w / 3) {
        canvas.drawLine(Offset(0, g), Offset(w, g), g1);
        canvas.drawLine(Offset(g, 0), Offset(g, h), g1);
      }
      final border = RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5, 0.5, w - 1, h - 1),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(border, g2);
    } else {
      final d1 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.22);
      final d2 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.14);
      for (var o = -w; o <= w; o += 4.0) {
        canvas.drawLine(Offset(o, 0), Offset(o + w, h), d1);
      }
      for (var o = -h; o <= w; o += 4.0) {
        canvas.drawLine(Offset(o, h), Offset(o + w, 0), d2);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EffBarPatternLegendPainter oldDelegate) {
    return oldDelegate.pattern != pattern || oldDelegate.baseColor != baseColor;
  }
}

/// Web：策略效能——每日波动率、现金收益率%（较 UTC 月初）、策略能效；全账户对比折线可选账户，明细区下拉切换账户（日线波动全站共用缓存）。
/// 明细表不展示权益/ATR 列；后端 API 仍可能返回这些字段供其他端使用。
class WebStrategyPerformanceScreen extends StatefulWidget {
  const WebStrategyPerformanceScreen({super.key, this.sharedBots = const []});

  final List<UnifiedTradingBot> sharedBots;

  @override
  State<WebStrategyPerformanceScreen> createState() =>
      _WebStrategyPerformanceScreenState();
}

/// 策略能效分档（按账户均原始比值）：小于 0.25 灰、0.25–0.5 绿、≥0.5 深绿（界面展示为×100 的 %）。
enum _EffBand { gray, green, darkGreen }

class _BotEfficiencyBundle {
  _BotEfficiencyBundle({required this.bot, this.response, this.fetchError});

  final UnifiedTradingBot bot;
  final StrategyDailyEfficiencyResponse? response;
  final String? fetchError;
  _EffBand band = _EffBand.gray;
  double scoreForChart = 0;

  bool get fetchOk => fetchError == null;
  bool get hasEfficiencyData =>
      response != null && response!.success && response!.rows.isNotEmpty;

  static double? _averageRatio(StrategyDailyEfficiencyResponse eff) {
    final ratios = eff.rows
        .map((e) => e.efficiencyRatio)
        .whereType<double>()
        .where((r) => r.isFinite)
        .toList();
    if (ratios.isEmpty) return null;
    var s = 0.0;
    for (final r in ratios) {
      s += r;
    }
    return s / ratios.length;
  }

  static _EffBand bandForScore(double? v) {
    if (v == null || !v.isFinite) return _EffBand.gray;
    if (v < 0.25) return _EffBand.gray;
    if (v < 0.5) return _EffBand.green;
    return _EffBand.darkGreen;
  }

  static _BotEfficiencyBundle fromLoad(
    UnifiedTradingBot bot,
    StrategyDailyEfficiencyResponse? response,
    String? fetchError,
  ) {
    final b = _BotEfficiencyBundle(
      bot: bot,
      response: response,
      fetchError: fetchError,
    );
    if (response != null &&
        response.success &&
        _averageRatio(response) != null) {
      b.scoreForChart = _averageRatio(response)!;
    }
    return b;
  }
}

class _WebStrategyPerformanceScreenState
    extends State<WebStrategyPerformanceScreen> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _bots = [];
  List<_BotEfficiencyBundle> _bundles = [];
  bool _loading = true;
  String? _loadError;

  /// 全账户对比折线图：选中的 botId（默认可对比账户全选）。
  Set<String> _comparisonChartSelectedBotIds = {};

  /// 下方单账户详情的当前 botId（下拉切换）。
  String? _selectedDetailBotId;

  /// 最近一个月窗口：按 30 天展示，图表与表格统一截断。
  static const int _efficiencyDays = 30;
  static const String _preferredAccountId = 'Alang_Sandbox';
  static const List<String> _preferredAccountNameKeywords = ['阿郎测试', 'alang'];

  /// 按 UTC 日期升序后仅保留末尾 [maxDays] 条，保证图表/表格与「最近一月」窗口一致。
  static List<StrategyDailyEfficiencyRow> _limitRowsToRecentDays(
    List<StrategyDailyEfficiencyRow> rows,
    int maxDays,
  ) {
    if (rows.isEmpty) return [];
    final copy = List<StrategyDailyEfficiencyRow>.from(rows)
      ..sort((a, b) => a.day.compareTo(b.day));
    if (copy.length <= maxDays) return copy;
    return copy.sublist(copy.length - maxDays);
  }

  bool _isPreferredAccount(UnifiedTradingBot bot) {
    if (bot.tradingbotId == _preferredAccountId) return true;
    final name = (bot.tradingbotName ?? '').trim().toLowerCase();
    if (name.isEmpty) return false;
    return _preferredAccountNameKeywords.any((k) => name.contains(k));
  }

  String? _pickPreferredDetailBotId(List<_BotEfficiencyBundle> loaded) {
    for (final b in loaded) {
      if (!b.fetchOk || !b.hasEfficiencyData) continue;
      if (_isPreferredAccount(b.bot)) return b.bot.tradingbotId;
    }
    return null;
  }

  static const Color _bandGray = Color(0xFF6B7280);
  static const Color _bandGreen = Color(0xFF4ADE80);
  static const Color _bandDarkGreen = Color(0xFF166534);

  Future<void> _loadBots() async {
    if (kDebugMode) {
      debugPrint(
        '[WebStrategyPerf] _loadBots sharedIn=${widget.sharedBots.length}',
      );
    }
    if (widget.sharedBots.isNotEmpty) {
      setState(() => _bots = List.from(widget.sharedBots));
      return;
    }
    final baseUrl = await _prefs.backendBaseUrl;
    final token = await _prefs.authToken;
    final api = ApiClient(baseUrl, token: token);
    final resp = await api.getTradingBots();
    if (!mounted) return;
    setState(() => _bots = resp.botList);
    if (kDebugMode) {
      debugPrint('[WebStrategyPerf] _loadBots fetched count=${_bots.length}');
    }
  }

  Future<void> _loadAllEfficiency() async {
    if (_bots.isEmpty) {
      if (kDebugMode) {
        debugPrint('[WebStrategyPerf] _loadAllEfficiency skip empty bots');
      }
      setState(() {
        _bundles = [];
        _loading = false;
        _comparisonChartSelectedBotIds = {};
        _selectedDetailBotId = null;
      });
      return;
    }
    if (kDebugMode) {
      debugPrint(
        '[WebStrategyPerf] _loadAllEfficiency start bots=${_bots.length}',
      );
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final loaded = await Future.wait(
        _bots.map((b) async {
          try {
            final r = await api.getStrategyDailyEfficiency(
              b.tradingbotId,
              days: _efficiencyDays,
            );
            return _BotEfficiencyBundle.fromLoad(b, r, null);
          } catch (e) {
            return _BotEfficiencyBundle.fromLoad(b, null, e.toString());
          }
        }),
      );
      if (!mounted) return;
      _applyEffBands(loaded);
      if (kDebugMode) {
        final ok = loaded.where((b) => b.fetchOk).length;
        debugPrint(
          '[WebStrategyPerf] _loadAllEfficiency done bundles=${loaded.length} fetchOk=$ok',
        );
      }
      setState(() {
        _bundles = loaded;
        _loading = false;
        final withData = loaded
            .where((b) => b.fetchOk && b.hasEfficiencyData)
            .map((b) => b.bot.tradingbotId)
            .toSet();
        final preferredId = _pickPreferredDetailBotId(loaded);
        if (preferredId != null) {
          _comparisonChartSelectedBotIds = {preferredId};
        } else {
          _comparisonChartSelectedBotIds.removeWhere(
            (id) => !withData.contains(id),
          );
          if (_comparisonChartSelectedBotIds.isEmpty && withData.isNotEmpty) {
            _comparisonChartSelectedBotIds = Set<String>.from(withData);
          }
        }
        final sorted = _sortedBundles(loaded);
        final sortedIds = sorted.map((b) => b.bot.tradingbotId).toList();
        if (preferredId != null && sortedIds.contains(preferredId)) {
          _selectedDetailBotId = preferredId;
        } else if (_selectedDetailBotId == null ||
            !sortedIds.contains(_selectedDetailBotId)) {
          _selectedDetailBotId = sortedIds.isNotEmpty ? sortedIds.first : null;
        }
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[WebStrategyPerf] _loadAllEfficiency error $e');
      }
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _bundles = [];
        _loading = false;
        _comparisonChartSelectedBotIds = {};
        _selectedDetailBotId = null;
      });
    }
  }

  void _applyEffBands(List<_BotEfficiencyBundle> list) {
    for (final b in list) {
      b.band = _BotEfficiencyBundle.bandForScore(
        b.hasEfficiencyData ? b.scoreForChart : null,
      );
    }
  }

  static Color _bandColor(_EffBand t) {
    switch (t) {
      case _EffBand.gray:
        return _bandGray;
      case _EffBand.green:
        return _bandGreen;
      case _EffBand.darkGreen:
        return _bandDarkGreen;
    }
  }

  static String _bandLabel(_EffBand t) {
    switch (t) {
      case _EffBand.gray:
        return '偏低';
      case _EffBand.green:
        return '中等';
      case _EffBand.darkGreen:
        return '优良';
    }
  }

  static Color _efficiencyPointColor(double? v) {
    if (v == null || !v.isFinite) return _bandGray;
    if (v < 0.25) return _bandGray;
    if (v < 0.5) return _bandGreen;
    return _bandDarkGreen;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadBots();
    if (!mounted) return;
    await _loadAllEfficiency();
  }

  /// 金额类：表内展示为整数。
  static String _fmtIntAmount(double? v) {
    if (v == null || !v.isFinite) return '—';
    return v.round().toString();
  }

  /// 价格波幅 |高−低|：×1e9 后取整展示。
  static String _fmtTrNano(double? v) {
    if (v == null || !v.isFinite) return '—';
    return (v * 1e9).round().toString();
  }

  /// 百分数：固定两位小数 + `%`。
  static String _fmtPctTwo(double? v) {
    if (v == null || !v.isFinite) return '—';
    return '${v.toStringAsFixed(2)}%';
  }

  /// 策略能效：服务端为 cash_delta÷(TR×1e9)；界面以百分比展示（×100），一位小数。
  static String _fmtEfficiencyCell(double? v) {
    if (v == null || !v.isFinite) return '—';
    return '${(v * 100).toStringAsFixed(1)}%';
  }

  /// 对比图 Y 轴已用「能效×100」；此处格式化为一位小数 + `%`。
  static String _fmtAxisEfficiency(double v) {
    if (!v.isFinite) return '';
    return '${v.toStringAsFixed(1)}%';
  }

  /// 数据表列头：将 `2026-3-1`、`2026-03-1 9`、`2026-03-01T00:00:00` 等统一为 `YYYY-MM-DD`。
  static String _fmtEfficiencyDayHeader(String rawDay) {
    final raw = rawDay.trim();
    if (raw.isEmpty) return rawDay;
    var datePart = raw.split(RegExp(r'\s+')).first;
    if (datePart.contains('T')) {
      datePart = datePart.split('T').first;
    }
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(datePart);
    if (m == null) return rawDay;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return rawDay;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return rawDay;
    final ys = y.toString().padLeft(4, '0');
    final ms = mo.toString().padLeft(2, '0');
    final ds = d.toString().padLeft(2, '0');
    return '$ys-$ms-$ds';
  }

  static Widget _chartLegendRow(
    BuildContext context,
    Color color,
    String label, {
    bool isLine = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isLine)
          Container(
            width: 22,
            height: 3,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          )
        else
          Container(
            width: 12,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        const SizedBox(width: 8),
        Text(
          label,
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
        ),
      ],
    );
  }

  /// 与 Lightweight Charts 内柱形图纹一致：波动率斜纹、现金收益率网格。
  static Widget _chartBarPatternLegendRow(
    BuildContext context, {
    required _EffBarHatchPattern pattern,
    required Color baseColor,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 14,
          child: CustomPaint(
            painter: _EffBarPatternLegendPainter(
              pattern: pattern,
              baseColor: baseColor,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildBandLegend(BuildContext context) {
    return Wrap(
      spacing: 20,
      runSpacing: 8,
      children: [
        _bandLegendChip(context, _bandGray, '偏低（能效<25.0%）'),
        _bandLegendChip(context, _bandGreen, '中等（25.0%–50.0%）'),
        _bandLegendChip(context, _bandDarkGreen, '优良（≥50.0%）'),
      ],
    );
  }

  static Widget _bandLegendChip(
    BuildContext context,
    Color color,
    String text,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
        ),
      ],
    );
  }

  static const List<Color> _comparisonLineColors = [
    Color(0xFF7EC850),
    Color(0xFF3B82F6),
    Color(0xFFEAB308),
    Color(0xFFEF4444),
    Color(0xFFA855F7),
    Color(0xFF14B8A6),
    Color(0xFFF97316),
    Color(0xFFEC4899),
  ];

  List<_BotEfficiencyBundle> _sortedBundles([List<_BotEfficiencyBundle>? src]) {
    final copy = List<_BotEfficiencyBundle>.from(src ?? _bundles);
    int bandOrder(_EffBand t) {
      switch (t) {
        case _EffBand.darkGreen:
          return 0;
        case _EffBand.green:
          return 1;
        case _EffBand.gray:
          return 2;
      }
    }

    copy.sort((a, b) {
      final c = bandOrder(a.band).compareTo(bandOrder(b.band));
      if (c != 0) return c;
      return b.scoreForChart.compareTo(a.scoreForChart);
    });
    return copy;
  }

  _BotEfficiencyBundle? _bundleForSelectedDetail() {
    final id = _selectedDetailBotId;
    if (id == null) return null;
    for (final b in _bundles) {
      if (b.bot.tradingbotId == id) return b;
    }
    return null;
  }

  Widget _comparisonChartAccountFilters(List<_BotEfficiencyBundle> candidates) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '折线显示账户：',
            style: AppFinanceStyle.labelTextStyle(
              context,
            ).copyWith(fontSize: 12),
          ),
          TextButton(
            onPressed: () => setState(() {
              _comparisonChartSelectedBotIds = {
                for (final b in candidates) b.bot.tradingbotId,
              };
            }),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: () =>
                setState(() => _comparisonChartSelectedBotIds = {}),
            child: const Text('清空'),
          ),
          for (final b in candidates)
            FilterChip(
              label: Text(
                b.bot.tradingbotName ?? b.bot.tradingbotId,
                style: const TextStyle(fontSize: 12),
              ),
              selected: _comparisonChartSelectedBotIds.contains(
                b.bot.tradingbotId,
              ),
              onSelected: (v) {
                setState(() {
                  final id = b.bot.tradingbotId;
                  if (v) {
                    _comparisonChartSelectedBotIds.add(id);
                  } else {
                    _comparisonChartSelectedBotIds.remove(id);
                  }
                });
              },
            ),
        ],
      ),
    );
  }

  /// 全账户：按日期对齐的能效比值折线，便于发现长期走弱、需人工关注的账户。
  Widget _buildComparisonChart(BuildContext context) {
    final candidates = _bundles
        .where((b) => b.fetchOk && b.hasEfficiencyData)
        .toList();
    final forChart = candidates
        .where(
          (b) => _comparisonChartSelectedBotIds.contains(b.bot.tradingbotId),
        )
        .toList();
    if (candidates.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Text(
          '暂无可对比的能效数据（请检查各账户接口返回）',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 13),
        ),
      );
    }
    if (forChart.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _comparisonChartAccountFilters(candidates),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '请至少选择一个账户以显示对比折线图。',
              style: AppFinanceStyle.labelTextStyle(
                context,
              ).copyWith(fontSize: 13),
            ),
          ),
        ],
      );
    }
    final daySet = <String>{};
    for (final b in forChart) {
      for (final r in b.response!.rows) {
        daySet.add(r.day);
      }
    }
    var allDays = daySet.toList()..sort();
    if (allDays.length > _efficiencyDays) {
      allDays = allDays.sublist(allDays.length - _efficiencyDays);
    }
    if (allDays.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _comparisonChartAccountFilters(candidates),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '暂无按日能效点',
              style: AppFinanceStyle.labelTextStyle(
                context,
              ).copyWith(fontSize: 13),
            ),
          ),
        ],
      );
    }
    final dayToX = <String, int>{
      for (var i = 0; i < allDays.length; i++) allDays[i]: i,
    };
    double? minY;
    double? maxY;
    final lineBars = <LineChartBarData>[];
    final plottedBundles = <_BotEfficiencyBundle>[];
    for (var bi = 0; bi < forChart.length; bi++) {
      final bundle = forChart[bi];
      final byDay = {
        for (final r in bundle.response!.rows) r.day: r.efficiencyRatio,
      };
      final spots = <FlSpot>[];
      for (final day in allDays) {
        final ratio = byDay[day];
        if (ratio != null && ratio.isFinite) {
          final yPct = ratio * 100;
          spots.add(FlSpot(dayToX[day]!.toDouble(), yPct));
          final my = minY;
          final xy = maxY;
          minY = my == null ? yPct : math.min(yPct, my);
          maxY = xy == null ? yPct : math.max(yPct, xy);
        }
      }
      if (spots.length < 2) continue;
      final colorIdx = plottedBundles.length;
      plottedBundles.add(bundle);
      final c = _comparisonLineColors[colorIdx % _comparisonLineColors.length];
      lineBars.add(
        LineChartBarData(
          spots: spots,
          color: c,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }
    if (lineBars.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _comparisonChartAccountFilters(candidates),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '所选账户有效能效点不足（至少需要 2 个交易日连成线）。',
              style: AppFinanceStyle.labelTextStyle(
                context,
              ).copyWith(fontSize: 13),
            ),
          ),
        ],
      );
    }
    var lo = minY ?? 0;
    var hi = maxY ?? 1;
    if (lo == hi) {
      lo -= 1e-9;
      hi += 1e-9;
    }
    final pad = (hi - lo) * 0.12;
    final chartMinY = lo - pad;
    final chartMaxY = hi + pad;
    if (chartMinY == chartMaxY) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _comparisonChartAccountFilters(candidates),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '能效 Y 轴范围无效',
              style: AppFinanceStyle.labelTextStyle(
                context,
              ).copyWith(fontSize: 13),
            ),
          ),
        ],
      );
    }

    final labelStep = allDays.length <= _efficiencyDays
        ? 1
        : (allDays.length / 6).ceil().clamp(1, allDays.length);

    final viewW = MediaQuery.sizeOf(context).width;
    final chartScrollMinW = math
        .max(viewW - 64, math.max(720.0, allDays.length * 40.0 + 120))
        .toDouble();
    final chartPlotW = math.max(chartScrollMinW - 40, 560.0).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _comparisonChartAccountFilters(candidates),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: chartScrollMinW),
            child: Padding(
              padding: const EdgeInsets.only(left: 20, right: 20, bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: chartPlotW,
                        height: 280,
                        child: LineChart(
                          LineChartData(
                            minX: 0,
                            maxX: (allDays.length - 1).toDouble(),
                            minY: chartMinY,
                            maxY: chartMaxY,
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: false,
                              getDrawingHorizontalLine: (v) => FlLine(
                                color: Colors.white.withValues(alpha: 0.06),
                                strokeWidth: 1,
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            titlesData: FlTitlesData(
                              show: true,
                              topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 52,
                                  getTitlesWidget: (v, m) => Text(
                                    _fmtAxisEfficiency(v),
                                    style: TextStyle(
                                      color: AppFinanceStyle.labelColor
                                          .withValues(alpha: 0.85),
                                      fontSize: 9,
                                    ),
                                  ),
                                ),
                              ),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 28,
                                  interval: labelStep.toDouble(),
                                  getTitlesWidget: (v, m) {
                                    final i = v.round();
                                    if (i < 0 || i >= allDays.length) {
                                      return const SizedBox.shrink();
                                    }
                                    final d = allDays[i];
                                    final short = d.length >= 10
                                        ? d.substring(5)
                                        : d;
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        short,
                                        style: TextStyle(
                                          color: AppFinanceStyle.labelColor
                                              .withValues(alpha: 0.85),
                                          fontSize: 9,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            lineTouchData: LineTouchData(
                              enabled: true,
                              touchTooltipData: LineTouchTooltipData(
                                getTooltipColor: (_) => AppFinanceStyle
                                    .cardBackground
                                    .withValues(alpha: 0.95),
                                tooltipPadding: const EdgeInsets.all(10),
                                getTooltipItems: (touchedSpots) {
                                  return touchedSpots
                                      .map((s) {
                                        final bar = s.barIndex;
                                        if (bar < 0 ||
                                            bar >= plottedBundles.length) {
                                          return null;
                                        }
                                        final xi = s.x.round().clamp(
                                          0,
                                          allDays.length - 1,
                                        );
                                        final day = allDays[xi];
                                        final name =
                                            plottedBundles[bar]
                                                .bot
                                                .tradingbotName ??
                                            plottedBundles[bar]
                                                .bot
                                                .tradingbotId;
                                        return LineTooltipItem(
                                          '$name · $day\n策略能效 ${_fmtAxisEfficiency(s.y)}',
                                          TextStyle(
                                            color: AppFinanceStyle.valueColor,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        );
                                      })
                                      .whereType<LineTooltipItem>()
                                      .toList();
                                },
                              ),
                            ),
                            lineBarsData: lineBars,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 280),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (
                              var bi = 0;
                              bi < plottedBundles.length;
                              bi++
                            ) ...[
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 14,
                                    height: 3,
                                    decoration: BoxDecoration(
                                      color:
                                          _comparisonLineColors[bi %
                                              _comparisonLineColors.length],
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    plottedBundles[bi].bot.tradingbotName ??
                                        plottedBundles[bi].bot.tradingbotId,
                                    style: AppFinanceStyle.labelTextStyle(
                                      context,
                                    ).copyWith(fontSize: 11),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _transposedMetricsTable(
    BuildContext context,
    List<StrategyDailyEfficiencyRow> rows,
  ) {
    if (rows.isEmpty) {
      return Text('无日明细', style: AppFinanceStyle.labelTextStyle(context));
    }
    const labelW = 100.0;
    const cellW = 92.0;
    final columnWidths = <int, TableColumnWidth>{
      0: const FixedColumnWidth(labelW),
      for (var i = 0; i < rows.length; i++)
        i + 1: const FixedColumnWidth(cellW),
    };
    final hdrStyle = TextStyle(
      color: AppFinanceStyle.valueColor,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    final labStyle = AppFinanceStyle.labelTextStyle(
      context,
    ).copyWith(fontSize: 13);
    // 与主题 body 一致，避免纯 TextStyle 与「每日波动率%」等行视觉字号不一致
    final valStyle = (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
        .copyWith(fontSize: 13, color: AppFinanceStyle.valueColor);
    // 策略能效行：浅绿底 + 字号比其他数据行大 1
    const effRowFont = 14;
    final effRowDecoration = BoxDecoration(
      color: const Color(0xFF86EFAC).withValues(alpha: 0.14),
    );

    TableRow row(List<Widget> cells) => TableRow(children: cells);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: Table(
        columnWidths: columnWidths,
        border: TableBorder.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.5,
        ),
        children: [
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Text('指标', style: hdrStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 10,
                ),
                child: Text(
                  _fmtEfficiencyDayHeader(e.day),
                  style: hdrStyle,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('每日波动×1e9', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtTrNano(e.tr),
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('每日波动率%', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtPctTwo(e.trPct),
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('当日现金增量', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtIntAmount(e.cashDeltaUsdt),
                  style: valStyle.copyWith(
                    color: (e.cashDeltaUsdt ?? 0) > 0
                        ? AppFinanceStyle.profitGreenEnd
                        : AppFinanceStyle.valueColor,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          row([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('现金收益率%', style: labStyle),
            ),
            ...rows.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  _fmtPctTwo(e.cashDeltaPct),
                  style: valStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ]),
          TableRow(
            decoration: effRowDecoration,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Text(
                  '策略能效',
                  style: labStyle.copyWith(fontSize: effRowFont.toDouble()),
                ),
              ),
              ...rows.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 8,
                  ),
                  child: Text(
                    _fmtEfficiencyCell(e.efficiencyRatio),
                    style: valStyle.copyWith(
                      fontSize: effRowFont.toDouble(),
                      color: _efficiencyPointColor(e.efficiencyRatio),
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDetailBotDropdown(
    BuildContext context, {
    required List<_BotEfficiencyBundle> sorted,
    required String? selectedDetailBotId,
    required ValueChanged<String> onChanged,
  }) {
    final heading = AppFinanceStyle.accountProfitOverviewHeadingStyle(context);
    final titleSz = Theme.of(context).textTheme.titleLarge?.fontSize ?? 22;
    final dropdownTextStyle = heading.copyWith(
      fontSize: math.max(
        AppFinanceStyle.webAccountProfitBotDropdownFontSize,
        titleSz - 2,
      ),
      fontWeight: FontWeight.w600,
      color: AppFinanceStyle.valueColor,
    );
    final maxW = (MediaQuery.sizeOf(context).width * 0.45).clamp(160.0, 320.0);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxW,
        minHeight: kMinInteractiveDimension,
      ),
      child: Theme(
        data: Theme.of(
          context,
        ).copyWith(canvasColor: AppFinanceStyle.cardBackground),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            iconSize: 24,
            itemHeight: 48,
            value: sorted.any((b) => b.bot.tradingbotId == selectedDetailBotId)
                ? selectedDetailBotId
                : null,
            hint: Text('选择账户', style: dropdownTextStyle),
            icon: Icon(Icons.arrow_drop_down, color: heading.color, size: 24),
            dropdownColor: AppFinanceStyle.cardBackground.withValues(
              alpha: 0.98,
            ),
            style: dropdownTextStyle,
            items: [
              for (final b in sorted)
                DropdownMenuItem<String>(
                  value: b.bot.tradingbotId,
                  child: Text(
                    b.bot.tradingbotName ?? b.bot.tradingbotId,
                    style: dropdownTextStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v == null) return;
              onChanged(v);
            },
          ),
        ),
      ),
    );
  }

  /// 明细卡片抬头：左侧档位色块，右侧靠右为分档说明 + 账户下拉（与账户名称合一）。
  Widget _detailCardHeaderRow(
    BuildContext context, {
    required _EffBand band,
    required List<_BotEfficiencyBundle> sortedForDropdown,
    required String? selectedDetailBotId,
    required ValueChanged<String> onDetailBotChanged,
    Widget? bandTrailing,
    double dotTopMargin = 5,
    double dotBorderRadius = 3,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 10,
          height: 10,
          margin: EdgeInsets.only(top: dotTopMargin),
          decoration: BoxDecoration(
            color: _bandColor(band),
            borderRadius: BorderRadius.circular(dotBorderRadius),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.end,
              children: [
                if (bandTrailing != null) bandTrailing,
                _buildDetailBotDropdown(
                  context,
                  sorted: sortedForDropdown,
                  selectedDetailBotId: selectedDetailBotId,
                  onChanged: onDetailBotChanged,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOneAccountCard(
    BuildContext context,
    _BotEfficiencyBundle bundle, {
    required List<_BotEfficiencyBundle> sortedForDropdown,
    required String? selectedDetailBotId,
    required ValueChanged<String> onDetailBotChanged,
  }) {
    if (!bundle.fetchOk) {
      return FinanceCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailCardHeaderRow(
              context,
              band: bundle.band,
              sortedForDropdown: sortedForDropdown,
              selectedDetailBotId: selectedDetailBotId,
              onDetailBotChanged: onDetailBotChanged,
              dotBorderRadius: 2,
              dotTopMargin: 4,
            ),
            const SizedBox(height: 8),
            Text(
              bundle.fetchError ?? '加载失败',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
      );
    }
    final eff = bundle.response!;
    if (!eff.success) {
      return FinanceCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailCardHeaderRow(
              context,
              band: bundle.band,
              sortedForDropdown: sortedForDropdown,
              selectedDetailBotId: selectedDetailBotId,
              onDetailBotChanged: onDetailBotChanged,
              dotBorderRadius: 2,
              dotTopMargin: 4,
              bandTrailing: Text(
                _bandLabel(bundle.band),
                style: TextStyle(
                  color: _bandColor(bundle.band),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
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
    final rows = _limitRowsToRecentDays(eff.rows, _efficiencyDays);
    // cash_basis：account_snapshots_cash 为历史枚举名；服务端数据来自表 account_balance_snapshots。
    final cashNote = switch (eff.cashBasis) {
      'account_snapshots_cash' => '现金变动来自（availEq），按自然日汇总。',
      _ => '无历史快照：按 K 线日期补零增量，现金收益率% 与策略能效在无分母处为「—」或 0。',
    };
    final initialCash = rows
        .map((e) => e.monthStartCash)
        .whereType<double>()
        .cast<double?>()
        .firstWhere((v) => v != null && v.isFinite, orElse: () => null);

    return FinanceCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _detailCardHeaderRow(
            context,
            band: bundle.band,
            sortedForDropdown: sortedForDropdown,
            selectedDetailBotId: selectedDetailBotId,
            onDetailBotChanged: onDetailBotChanged,
            bandTrailing: Text(
              '${_bandLabel(bundle.band)} · 均比 ${_fmtEfficiencyCell(bundle.hasEfficiencyData ? bundle.scoreForChart : null)}',
              style: TextStyle(
                color: _bandColor(bundle.band),
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '${eff.instId}：每日波动率% = |最高−最低|÷收盘 × 100%；'
            '策略能效 = 当日现金增量÷（|最高−最低| × 1e9）；'
            '表格与图中以该比值×100 显示为百分比（一位小数）。',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
              fontSize: 14,
              height: 1.45,
              color: AppFinanceStyle.textDefault.withValues(alpha: 0.58),
            ),
          ),

          const SizedBox(height: 16),
          DefaultTabController(
            length: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  color: Colors.transparent,
                  child: DecoratedBox(
                    decoration: AppFinanceStyle.webSubtleInsetPanelDecoration(),
                    child: TabBar(
                      labelColor: AppFinanceStyle.profitGreenEnd,
                      unselectedLabelColor: AppFinanceStyle.labelColor
                          .withValues(alpha: 0.55),
                      labelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      indicatorColor: AppFinanceStyle.profitGreenEnd,
                      indicatorWeight: 2.5,
                      indicatorSize: TabBarIndicatorSize.tab,
                      overlayColor: WidgetStateProperty.all(Colors.transparent),
                      tabs: const [
                        Tab(text: '图表'),
                        Tab(text: '数据'),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  height: 460,
                  child: TabBarView(
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      LayoutBuilder(
                        builder: (context, c) {
                          final mw = math
                              .max(
                                c.maxWidth.isFinite ? c.maxWidth : 720.0,
                                720.0,
                              )
                              .toDouble();
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(minWidth: mw),
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  top: 10,
                                  right: 8,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: 16,
                                      runSpacing: 6,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        _chartBarPatternLegendRow(
                                          context,
                                          pattern: _EffBarHatchPattern.diagonal,
                                          baseColor: const Color.fromRGBO(
                                            245,
                                            245,
                                            245,
                                            0.58,
                                          ),
                                          label:
                                              '每日波动率%（上半轴柱，斜纹；着色：白/黄/红 <6% / 6–10% / >10%）',
                                        ),
                                        _chartBarPatternLegendRow(
                                          context,
                                          pattern: _EffBarHatchPattern.grid,
                                          baseColor: const Color.fromRGBO(
                                            34,
                                            197,
                                            94,
                                            0.62,
                                          ),
                                          label:
                                              '现金收益率%（下半轴柱，网格；着色：灰/白/绿 <0.5% / 0.5–1% / ≥1%）',
                                        ),
                                        _chartLegendRow(
                                          context,
                                          const Color(0xFF6B7280),
                                          '策略能效折线（右轴 %；灰/绿/深绿：<25.0 / 25.0–50.0 / ≥50.0）',
                                          isLine: true,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    StrategyEfficiencyLightweightChart(
                                      rows: rows,
                                      height: 360,
                                    ),
                                    Text(
                                      '图表：TradingView Lightweight Charts · 可横向滑动查看',
                                      style: AppFinanceStyle.labelTextStyle(
                                        context,
                                      ).copyWith(fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(top: 12),
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          Text(
                            '初始资金：${_fmtIntAmount(initialCash)}',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: const Color.fromARGB(
                                    255,
                                    208,
                                    208,
                                    216,
                                  ),
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            cashNote,
                            style: AppFinanceStyle.labelTextStyle(context)
                                .copyWith(
                                  fontSize: 12,
                                  color: AppFinanceStyle.labelColor.withValues(
                                    alpha: 0.65,
                                  ),
                                ),
                          ),
                          const SizedBox(height: 8),
                          _transposedMetricsTable(context, rows),
                        ],
                      ),
                    ],
                  ),
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
            await _loadAllEfficiency();
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (_loadError != null)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    24 + AppFinanceStyle.webSummaryTitleSpacing,
                    24,
                    8,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1600),
                        child: FinanceCard(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            _loadError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
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
              else ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    24 + AppFinanceStyle.webSummaryTitleSpacing,
                    24,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1600),
                        child: FinanceCard(
                          padding: EdgeInsets.zero,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  22,
                                  22,
                                  22,
                                  8,
                                ),
                                child: Text(
                                  '全账户策略能效对比',
                                  style:
                                      (Theme.of(context).textTheme.titleLarge ??
                                              const TextStyle())
                                          .copyWith(
                                            color: AppFinanceStyle.labelColor,
                                            fontSize:
                                                (Theme.of(context)
                                                        .textTheme
                                                        .titleLarge
                                                        ?.fontSize ??
                                                    22) +
                                                2,
                                            fontWeight: FontWeight.w600,
                                          ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  22,
                                  0,
                                  22,
                                  12,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  22,
                                  0,
                                  22,
                                  16,
                                ),
                                child: _buildBandLegend(context),
                              ),
                              _buildComparisonChart(context),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                  sliver: SliverToBoxAdapter(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1600),
                        child: Builder(
                          builder: (context) {
                            final sorted = _sortedBundles();
                            final detailBundle = _bundleForSelectedDetail();
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (detailBundle != null)
                                  _buildOneAccountCard(
                                    context,
                                    detailBundle,
                                    sortedForDropdown: sorted,
                                    selectedDetailBotId: _selectedDetailBotId,
                                    onDetailBotChanged: (v) {
                                      setState(() {
                                        _selectedDetailBotId = v;
                                      });
                                    },
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
