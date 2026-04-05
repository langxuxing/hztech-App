import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';

DateTime? _parseSnapshotAt(String raw) {
  if (raw.isEmpty) return null;
  final s = raw.length >= 19 ? raw.substring(0, 19) : raw;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

/// 从快照中取用于「时点余额」的数值（权益或现金）。
typedef MonthEndSnapshotValue = double Function(BotProfitSnapshot snapshot);

class _MonthStat {
  _MonthStat({required this.year, required this.month, required this.monthlyPnL});

  final int year;
  final int month;
  final double monthlyPnL;

  String get label => '$year-${month.toString().padLeft(2, '0')}';
}

// --- 共享计算逻辑 ---

List<BotProfitSnapshot> _sortedSnapshotsWithDates(List<BotProfitSnapshot> raw) {
  final withDates = <({DateTime d, BotProfitSnapshot s})>[];
  for (final s in raw) {
    final d = _parseSnapshotAt(s.snapshotAt);
    if (d != null) withDates.add((d: d, s: s));
  }
  withDates.sort((a, b) => a.d.compareTo(b.d));
  return withDates.map((e) => e.s).toList();
}

DateTime _defaultFocusedMonth(List<BotProfitSnapshot> sorted) {
  if (sorted.isEmpty) return DateTime(DateTime.now().year, DateTime.now().month);
  final last = _parseSnapshotAt(sorted.last.snapshotAt);
  if (last == null) return DateTime(DateTime.now().year, DateTime.now().month);
  return DateTime(last.year, last.month);
}

/// 有快照的最后一个自然月；无数据则为当前月。
DateTime focusedMonthFromProfitSnapshots(List<BotProfitSnapshot> raw) {
  final sorted = _sortedSnapshotsWithDates(raw);
  return _defaultFocusedMonth(sorted);
}

/// 将 [DailyRealizedPnlResponse.days] 中的 `YYYY-MM-DD` 转为当月「日序 -> 平仓笔数」。
Map<int, int> dailyCloseCountsMapForMonth(
  List<DailyRealizedPnlDayRow> rows,
  int year,
  int month,
) {
  final out = <int, int>{};
  for (final r in rows) {
    final p = r.day.split('-');
    if (p.length != 3) continue;
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) continue;
    if (y == year && m == month) out[d] = r.closeCount;
  }
  return out;
}

/// 将 [month] 限制在快照覆盖的首月～末月之间（按自然月）。
DateTime clampMonthToSnapshots(List<BotProfitSnapshot> raw, DateTime month) {
  final sorted = _sortedSnapshotsWithDates(raw);
  if (sorted.isEmpty) return DateTime(month.year, month.month);
  DateTime? first;
  DateTime? last;
  for (final s in sorted) {
    final d = _parseSnapshotAt(s.snapshotAt);
    if (d == null) continue;
    final m = DateTime(d.year, d.month);
    final prevFirst = first;
    final prevLast = last;
    first = prevFirst == null || m.isBefore(prevFirst) ? m : prevFirst;
    last = prevLast == null || m.isAfter(prevLast) ? m : prevLast;
  }
  if (first == null || last == null) return DateTime(month.year, month.month);
  final f = first;
  final l = last;
  final t = DateTime(month.year, month.month);
  if (t.isBefore(f)) return f;
  if (t.isAfter(l)) return l;
  return t;
}

double _valueAtOrBefore(
  List<BotProfitSnapshot> sorted,
  DateTime instant,
  MonthEndSnapshotValue valueAt,
) {
  double? v;
  for (final s in sorted) {
    final d = _parseSnapshotAt(s.snapshotAt);
    if (d == null) continue;
    if (!d.isAfter(instant)) {
      v = valueAt(s);
    } else {
      break;
    }
  }
  return v ?? double.nan;
}

double _valueStrictlyBefore(
  List<BotProfitSnapshot> sorted,
  DateTime instant,
  MonthEndSnapshotValue valueAt,
) {
  double? v;
  for (final s in sorted) {
    final d = _parseSnapshotAt(s.snapshotAt);
    if (d == null) continue;
    if (d.isBefore(instant)) {
      v = valueAt(s);
    } else {
      break;
    }
  }
  return v ?? double.nan;
}

List<_MonthStat> _computeMonthlyStats(
  List<BotProfitSnapshot> sorted,
  MonthEndSnapshotValue valueAt,
  double fallbackBeforeFirst,
) {
  if (sorted.isEmpty) return [];
  final months = <String, void>{};
  for (final s in sorted) {
    final d = _parseSnapshotAt(s.snapshotAt);
    if (d == null) continue;
    months['${d.year}-${d.month}'] = null;
  }
  final keys = months.keys.toList()
    ..sort((a, b) {
      final pa = a.split('-');
      final pb = b.split('-');
      final ya = int.parse(pa[0]);
      final ma = int.parse(pa[1]);
      final yb = int.parse(pb[0]);
      final mb = int.parse(pb[1]);
      if (ya != yb) return ya.compareTo(yb);
      return ma.compareTo(mb);
    });
  final out = <_MonthStat>[];
  for (final key in keys) {
    final parts = key.split('-');
    final y = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    final firstDay = DateTime(y, m, 1);
    var startVal = fallbackBeforeFirst;
    for (final s in sorted) {
      final d = _parseSnapshotAt(s.snapshotAt);
      if (d == null) continue;
      if (d.isBefore(firstDay)) {
        startVal = valueAt(s);
      } else {
        break;
      }
    }
    var endVal = double.nan;
    for (final s in sorted) {
      final d = _parseSnapshotAt(s.snapshotAt);
      if (d != null && d.year == y && d.month == m) {
        endVal = valueAt(s);
      }
    }
    if (endVal.isFinite) {
      out.add(_MonthStat(year: y, month: m, monthlyPnL: endVal - startVal));
    }
  }
  return out;
}

Map<int, double> _dailyDeltaForMonth(
  List<BotProfitSnapshot> sorted,
  DateTime focusedMonth,
  MonthEndSnapshotValue valueAt,
  double fallbackBeforeFirst,
) {
  final y = focusedMonth.year;
  final m = focusedMonth.month;
  final lastDay = DateTime(y, m + 1, 0).day;
  final map = <int, double>{};
  for (var day = 1; day <= lastDay; day++) {
    final dayStart = DateTime(y, m, day);
    final dayEnd = DateTime(y, m, day, 23, 59, 59, 999);
    var eod = _valueAtOrBefore(sorted, dayEnd, valueAt);
    var sod = _valueStrictlyBefore(sorted, dayStart, valueAt);
    if (!eod.isFinite) continue;
    if (!sod.isFinite) sod = fallbackBeforeFirst;
    final pnl = eod - sod;
    if (pnl != 0 || _hasSnapshotOnDay(sorted, dayStart, dayEnd)) {
      map[day] = pnl;
    }
  }
  return map;
}

bool _hasSnapshotOnDay(
  List<BotProfitSnapshot> sorted,
  DateTime dayStart,
  DateTime dayEnd,
) {
  for (final s in sorted) {
    final d = _parseSnapshotAt(s.snapshotAt);
    if (d == null) continue;
    if (!d.isBefore(dayStart) && !d.isAfter(dayEnd)) return true;
  }
  return false;
}

double _barMaxY(List<_MonthStat> monthly) {
  if (monthly.isEmpty) return 1;
  var maxV = monthly.first.monthlyPnL;
  var minV = monthly.first.monthlyPnL;
  for (final e in monthly) {
    if (e.monthlyPnL > maxV) maxV = e.monthlyPnL;
    if (e.monthlyPnL < minV) minV = e.monthlyPnL;
  }
  if (maxV <= 0) return 1.0;
  final pad = (maxV - minV).abs() * 0.12 + 1;
  return maxV + pad;
}

double _barMinY(List<_MonthStat> monthly) {
  if (monthly.isEmpty) return -1;
  var maxV = monthly.first.monthlyPnL;
  var minV = monthly.first.monthlyPnL;
  for (final e in monthly) {
    if (e.monthlyPnL > maxV) maxV = e.monthlyPnL;
    if (e.monthlyPnL < minV) minV = e.monthlyPnL;
  }
  if (minV >= 0) return 0.0;
  final pad = (maxV - minV).abs() * 0.12 + 1;
  return minV - pad;
}

/// 截止 [endMonth]（含）之前最多 [maxBars] 个自然月的柱数据。
List<_MonthStat> _visibleMonthlyBars(
  List<_MonthStat> all,
  DateTime endMonth,
  int maxBars,
) {
  final filtered = all.where((s) {
    if (s.year > endMonth.year) return false;
    if (s.year == endMonth.year && s.month > endMonth.month) return false;
    return true;
  }).toList();
  if (filtered.length <= maxBars) return filtered;
  return filtered.sublist(filtered.length - maxBars);
}

DateTime _monthStatAsDateTime(_MonthStat s) => DateTime(s.year, s.month);

DateTime _clampEndMonthToData(List<_MonthStat> monthly, DateTime candidate) {
  if (monthly.isEmpty) return candidate;
  final first = _monthStatAsDateTime(monthly.first);
  final last = _monthStatAsDateTime(monthly.last);
  if (candidate.isBefore(first)) return first;
  if (candidate.isAfter(last)) return last;
  return DateTime(candidate.year, candidate.month);
}

/// 与 [_MonthEndValueCalendarPanelState._cellHeightForGrid] 使用同一套常数：
/// 在传入 [MonthEndValueCalendarPanel.gridMaxHeight] 为 [gridMaxHeight] 时，日历网格（表头 + 六行单元格）实际像素高度。
/// [compact] 须与对应面板的 [MonthEndValueCalendarPanel.compact] 一致（行间距 4 / 6）。
double calendarGridPixelHeightForCap(
  double gridMaxHeight, {
  bool compact = true,
}) {
  const headerH = 22.0;
  const rows = 6;
  final rowSpacing = compact ? 4.0 : 6.0;
  final avail =
      gridMaxHeight - headerH - rowSpacing - rows * rowSpacing;
  final cellHeight = (avail / rows).clamp(28.0, 58.0);
  return headerH + rowSpacing + rows * (cellHeight + rowSpacing);
}

// --- 柱状图卡片 ---

/// 月度时点余额差分：柱状图（自然月汇总），可选截止月份，最多展示 12 个月。
class MonthEndValueBarPanel extends StatefulWidget {
  const MonthEndValueBarPanel({
    super.key,
    required this.snapshots,
    required this.title,
    required this.description,
    required this.valueAt,
    required this.emptyMessage,
    this.maxBars = 12,
    this.compact = false,
    this.barChartHeight,
    /// 为 false 时由父级提供月份条（与 [selectedEndMonth]、[onSelectedEndMonthChanged] 配合）。
    this.showMonthNavigator = true,
    this.selectedEndMonth,
    this.onSelectedEndMonthChanged,
  });

  final List<BotProfitSnapshot> snapshots;
  final String title;
  final String description;
  final MonthEndSnapshotValue valueAt;
  final String emptyMessage;
  final int maxBars;
  /// 三列栅格等：缩小标题与说明，柱图高度由 [barChartHeight] 或缺省值决定。
  final bool compact;
  final double? barChartHeight;
  final bool showMonthNavigator;
  /// 受控：柱状图截止月（与日历「当前月」对齐时使用同一 [DateTime]）。
  final DateTime? selectedEndMonth;
  final ValueChanged<DateTime>? onSelectedEndMonthChanged;

  @override
  State<MonthEndValueBarPanel> createState() => _MonthEndValueBarPanelState();
}

class _MonthEndValueBarPanelState extends State<MonthEndValueBarPanel> {
  /// 用户选择的截止月；null 表示跟随数据最后一月（仅非受控时）。
  DateTime? _endMonthManual;

  bool get _controlled =>
      widget.selectedEndMonth != null && widget.onSelectedEndMonthChanged != null;

  @override
  void didUpdateWidget(covariant MonthEndValueBarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.snapshots, widget.snapshots) && !_controlled) {
      _endMonthManual = null;
    }
  }

  DateTime _effectiveEndMonth(List<_MonthStat> monthly) {
    if (monthly.isEmpty) {
      return DateTime(DateTime.now().year, DateTime.now().month);
    }
    final last = _monthStatAsDateTime(monthly.last);
    if (_controlled) {
      return _clampEndMonthToData(monthly, widget.selectedEndMonth!);
    }
    if (_endMonthManual == null) return last;
    return _clampEndMonthToData(monthly, _endMonthManual!);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sortedSnapshotsWithDates(widget.snapshots);
    final fallback = sorted.isEmpty ? 0.0 : sorted.first.initialBalance;
    final monthly = _computeMonthlyStats(sorted, widget.valueAt, fallback);
    final end = _effectiveEndMonth(monthly);
    final visible = _visibleMonthlyBars(monthly, end, widget.maxBars);
    final barH = widget.barChartHeight ?? (widget.compact ? 140.0 : 200.0);
    final titleStyle = widget.compact
        ? (Theme.of(context).textTheme.titleMedium ?? const TextStyle()).copyWith(
            color: AppFinanceStyle.labelColor,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          )
        : (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
            color: AppFinanceStyle.labelColor,
            fontSize: (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 4,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.title, style: titleStyle),
        if (!widget.compact) ...[
          const SizedBox(height: 8),
          Text(
            widget.description,
            style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
          ),
        ],
        if (monthly.isNotEmpty && !widget.compact) ...[
          const SizedBox(height: 8),
          Text(
            '使用左右箭头选择截止月份；柱状图展示此前最多 ${widget.maxBars} 个自然月（有快照的月份）。',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 11),
          ),
        ],
        SizedBox(height: widget.compact ? 6 : 12),
        if (monthly.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              widget.emptyMessage,
              style: TextStyle(color: AppFinanceStyle.labelColor, fontSize: 13),
            ),
          )
        else ...[
          if (widget.showMonthNavigator) ...[
            Row(
              children: [
                if (!widget.compact)
                  Text(
                    '截止月份',
                    style: AppFinanceStyle.labelTextStyle(context).copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                if (!widget.compact) const Spacer(),
                IconButton(
                  tooltip: '上一月',
                  visualDensity: widget.compact ? VisualDensity.compact : null,
                  padding: widget.compact ? EdgeInsets.zero : null,
                  constraints: widget.compact
                      ? const BoxConstraints(minWidth: 32, minHeight: 32)
                      : null,
                  icon: const Icon(Icons.chevron_left, color: AppFinanceStyle.valueColor),
                  onPressed: () {
                    final cur = _effectiveEndMonth(monthly);
                    final next = _clampEndMonthToData(
                      monthly,
                      DateTime(cur.year, cur.month - 1),
                    );
                    if (_controlled) {
                      widget.onSelectedEndMonthChanged!(next);
                    } else {
                      setState(() => _endMonthManual = next);
                    }
                  },
                ),
                Text(
                  '${end.year}-${end.month.toString().padLeft(2, '0')}',
                  style: TextStyle(
                    color: AppFinanceStyle.valueColor,
                    fontWeight: FontWeight.w600,
                    fontSize: widget.compact ? 12 : 14,
                  ),
                ),
                IconButton(
                  tooltip: '下一月',
                  visualDensity: widget.compact ? VisualDensity.compact : null,
                  padding: widget.compact ? EdgeInsets.zero : null,
                  constraints: widget.compact
                      ? const BoxConstraints(minWidth: 32, minHeight: 32)
                      : null,
                  icon: const Icon(Icons.chevron_right, color: AppFinanceStyle.valueColor),
                  onPressed: () {
                    final cur = _effectiveEndMonth(monthly);
                    final next = _clampEndMonthToData(
                      monthly,
                      DateTime(cur.year, cur.month + 1),
                    );
                    if (_controlled) {
                      widget.onSelectedEndMonthChanged!(next);
                    } else {
                      setState(() => _endMonthManual = next);
                    }
                  },
                ),
                if (widget.compact) const Spacer(),
              ],
            ),
            SizedBox(height: widget.compact ? 4 : 8),
          ] else
            SizedBox(height: widget.compact ? 2 : 4),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '当前截止月份之前无可用月份数据',
                style: TextStyle(color: AppFinanceStyle.labelColor, fontSize: 13),
              ),
            )
          else
            SizedBox(
              height: barH,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: _barMaxY(visible),
                  minY: _barMinY(visible),
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
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: widget.compact ? 32 : 40,
                        getTitlesWidget: (v, m) => Text(
                          v.toStringAsFixed(0),
                          style: TextStyle(
                            color: AppFinanceStyle.labelColor.withValues(alpha: 0.85),
                            fontSize: widget.compact ? 8 : 10,
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                      reservedSize: widget.compact ? 22 : 28,
                      getTitlesWidget: (v, m) {
                        final i = v.round();
                        if (i < 0 || i >= visible.length) return const SizedBox.shrink();
                        final label = visible[i].label;
                        final short = label.length >= 7 ? label.substring(2) : label;
                        return Padding(
                          padding: EdgeInsets.only(top: widget.compact ? 2 : 6),
                          child: Text(
                            short,
                            style: TextStyle(
                              color: AppFinanceStyle.labelColor.withValues(alpha: 0.9),
                              fontSize: widget.compact ? 7 : 9,
                            ),
                          ),
                        );
                      },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < visible.length; i++)
                      BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: visible[i].monthlyPnL,
                            width: 14,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                            color: visible[i].monthlyPnL >= 0
                                ? AppFinanceStyle.profitGreenEnd
                                : Colors.red.withValues(alpha: 0.85),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}

// --- 日历卡片 ---

/// 按日展示当月内相邻快照间的余额变化（着色与数值与权益版一致）。
class MonthEndValueCalendarPanel extends StatefulWidget {
  const MonthEndValueCalendarPanel({
    super.key,
    required this.snapshots,
    required this.title,
    required this.description,
    required this.valueAt,
    required this.emptyMessage,
    this.compact = false,
    this.showMonthNavigator = true,
    this.focusedMonth,
    this.onFocusedMonthChanged,
    /// 限制日历网格最大高度时，按比例缩小单元格（与柱图/折线同卡无内滚动）。
    this.gridMaxHeight,
    /// 按「日」索引的平仓笔数（与后端 UTC 日一致）；与 [snapshots] 日损益并列展示。
    this.dailyCloseCounts,
  });

  final List<BotProfitSnapshot> snapshots;
  final String title;
  final String description;
  final MonthEndSnapshotValue valueAt;
  final String emptyMessage;
  final bool compact;
  final bool showMonthNavigator;
  final DateTime? focusedMonth;
  final ValueChanged<DateTime>? onFocusedMonthChanged;
  final double? gridMaxHeight;
  final Map<int, int>? dailyCloseCounts;

  @override
  State<MonthEndValueCalendarPanel> createState() => _MonthEndValueCalendarPanelState();
}

class _MonthEndValueCalendarPanelState extends State<MonthEndValueCalendarPanel> {
  late DateTime _focusedMonth;

  bool get _controlled =>
      widget.focusedMonth != null && widget.onFocusedMonthChanged != null;

  @override
  void initState() {
    super.initState();
    _focusedMonth = _defaultFocusedMonth(_sortedSnapshotsWithDates(widget.snapshots));
  }

  @override
  void didUpdateWidget(covariant MonthEndValueCalendarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshots.isEmpty && widget.snapshots.isNotEmpty && !_controlled) {
      _focusedMonth = _defaultFocusedMonth(_sortedSnapshotsWithDates(widget.snapshots));
    }
  }

  DateTime _monthForBuild(List<BotProfitSnapshot> sorted) {
    if (_controlled) {
      return clampMonthToSnapshots(sorted, widget.focusedMonth!);
    }
    return _focusedMonth;
  }

  double _cellHeightForGrid() {
    if (widget.gridMaxHeight == null) {
      return widget.compact ? 34 : 48;
    }
    const headerH = 22.0;
    const rows = 6;
    final rowSpacing = widget.compact ? 4.0 : 6.0;
    final avail =
        widget.gridMaxHeight! - headerH - rowSpacing - rows * rowSpacing;
    return (avail / rows).clamp(28.0, 58.0);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sortedSnapshotsWithDates(widget.snapshots);
    final fallback = sorted.isEmpty ? 0.0 : sorted.first.initialBalance;
    final monthly = _computeMonthlyStats(sorted, widget.valueAt, fallback);
    final focus = _monthForBuild(sorted);
    final daily = _dailyDeltaForMonth(sorted, focus, widget.valueAt, fallback);
    final titleStyle = widget.compact
        ? (Theme.of(context).textTheme.titleMedium ?? const TextStyle()).copyWith(
            color: AppFinanceStyle.labelColor,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          )
        : (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
            color: AppFinanceStyle.labelColor,
            fontSize: (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 4,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.title, style: titleStyle),
        if (!widget.compact) ...[
          const SizedBox(height: 8),
          Text(
            widget.description,
            style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
          ),
        ],
        SizedBox(height: widget.compact ? 6 : 16),
        if (monthly.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              widget.emptyMessage,
              style: TextStyle(color: AppFinanceStyle.labelColor, fontSize: 13),
            ),
          )
        else ...[
          if (widget.showMonthNavigator) ...[
            Row(
              children: [
                const Spacer(),
                IconButton(
                  visualDensity: widget.compact ? VisualDensity.compact : null,
                  padding: widget.compact ? EdgeInsets.zero : null,
                  constraints: widget.compact
                      ? const BoxConstraints(minWidth: 32, minHeight: 32)
                      : null,
                  icon: const Icon(Icons.chevron_left, color: AppFinanceStyle.valueColor),
                  onPressed: () {
                    final next = DateTime(focus.year, focus.month - 1);
                    if (_controlled) {
                      widget.onFocusedMonthChanged!(
                        clampMonthToSnapshots(sorted, next),
                      );
                    } else {
                      setState(() => _focusedMonth = next);
                    }
                  },
                ),
                Text(
                  widget.compact
                      ? '${focus.year}-${focus.month.toString().padLeft(2, '0')}'
                      : '${focus.year}年${focus.month}月',
                  style: TextStyle(
                    color: AppFinanceStyle.valueColor,
                    fontWeight: FontWeight.w600,
                    fontSize: widget.compact ? 12 : 14,
                  ),
                ),
                IconButton(
                  visualDensity: widget.compact ? VisualDensity.compact : null,
                  padding: widget.compact ? EdgeInsets.zero : null,
                  constraints: widget.compact
                      ? const BoxConstraints(minWidth: 32, minHeight: 32)
                      : null,
                  icon: const Icon(Icons.chevron_right, color: AppFinanceStyle.valueColor),
                  onPressed: () {
                    final next = DateTime(focus.year, focus.month + 1);
                    if (_controlled) {
                      widget.onFocusedMonthChanged!(
                        clampMonthToSnapshots(sorted, next),
                      );
                    } else {
                      setState(() => _focusedMonth = next);
                    }
                  },
                ),
              ],
            ),
            SizedBox(height: widget.compact ? 4 : 8),
          ] else
            SizedBox(height: widget.compact ? 2 : 4),
          _CalendarGrid(
            year: focus.year,
            month: focus.month,
            dailyPnL: daily,
            dailyCloseCounts: widget.dailyCloseCounts,
            cellHeight: _cellHeightForGrid(),
            compact: widget.compact,
            headerFontSize: widget.compact ? 10 : 12,
            rowSpacing: widget.compact ? 4 : 6,
          ),
        ],
      ],
    );
  }
}

class _CalendarGrid extends StatelessWidget {
  const _CalendarGrid({
    required this.year,
    required this.month,
    required this.dailyPnL,
    this.dailyCloseCounts,
    this.cellHeight = 44,
    this.compact = false,
    this.headerFontSize = 12,
    this.rowSpacing = 6,
  });

  final int year;
  final int month;
  final Map<int, double> dailyPnL;
  final Map<int, int>? dailyCloseCounts;
  final double cellHeight;
  final bool compact;
  final double headerFontSize;
  final double rowSpacing;

  @override
  Widget build(BuildContext context) {
    const headers = ['一', '二', '三', '四', '五', '六', '日'];
    final firstWeekday = DateTime(year, month, 1).weekday;
    final leading = firstWeekday - 1;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final cells = <Widget?>[];

    for (var i = 0; i < leading; i++) {
      cells.add(null);
    }
    for (var d = 1; d <= daysInMonth; d++) {
      cells.add(_dayCell(context, d));
    }
    while (cells.length % 7 != 0) {
      cells.add(null);
    }

    return Column(
      children: [
        Row(
          children: [
            for (final h in headers)
              Expanded(
                child: Center(
                  child: Text(
                    h,
                    style: TextStyle(
                      color: AppFinanceStyle.labelColor.withValues(alpha: 0.75),
                      fontSize: headerFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        SizedBox(height: rowSpacing),
        for (var r = 0; r < cells.length / 7; r++)
          Padding(
            padding: EdgeInsets.only(bottom: rowSpacing),
            child: Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Expanded(
                    child: cells[r * 7 + c] ?? SizedBox(height: cellHeight),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dayCell(BuildContext context, int day) {
    final pnl = dailyPnL[day];
    final has = pnl != null;
    final borderColor = !has
        ? Colors.white.withValues(alpha: 0.06)
        : (pnl >= 0 ? AppFinanceStyle.profitGreenEnd : Colors.redAccent);
    final profitColor =
        !has ? AppFinanceStyle.labelColor : (pnl >= 0 ? AppFinanceStyle.profitGreenEnd : Colors.redAccent);
    final profitFontSize =
        (cellHeight * 0.36).clamp(compact ? 14.0 : 16.0, compact ? 19.0 : 23.0);
    final dayFontSize =
        (cellHeight * 0.26).clamp(compact ? 10.0 : 11.0, compact ? 12.0 : 14.0);
    final closeFontSize =
        (profitFontSize * 0.5).clamp(compact ? 7.5 : 8.0, compact ? 9.5 : 11.0);
    final closes = dailyCloseCounts?[day];

    if (!has) {
      return Container(
        height: cellHeight,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        alignment: Alignment.topRight,
        padding: const EdgeInsets.only(top: 4, right: 5),
        child: Text(
          '$day',
          style: TextStyle(
            color: AppFinanceStyle.labelColor.withValues(alpha: 0.45),
            fontSize: dayFontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Container(
      height: cellHeight,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 1),
      ),
      clipBehavior: Clip.none,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 4,
            right: 6,
            child: Text(
              '$day',
              style: TextStyle(
                color: const Color(0xFF111111),
                fontSize: dayFontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Positioned.fill(
            child: Align(
              alignment: const Alignment(0, 0.2),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${formatUiSignedUsdt2(pnl)} USDT',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: TextStyle(
                      color: profitColor,
                      fontSize: profitFontSize,
                      fontWeight: FontWeight.w800,
                      height: 1.05,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (closes != null && closes > 0)
            Positioned(
              right: 5,
              bottom: 3,
              child: Text(
                '$closes 笔平仓',
                style: TextStyle(
                  color: const Color(0xFF888888),
                  fontSize: closeFontSize,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
