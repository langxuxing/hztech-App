import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/finance_style.dart';

DateTime? _parseSnapshotAt(String raw) {
  if (raw.isEmpty) return null;
  final s = raw.length >= 19 ? raw.substring(0, 19) : raw;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

/// 月底权益差分统计 + 柱状图 + 可切换月份的日历（按日权益变化着色）。
class MonthEndProfitPanel extends StatefulWidget {
  const MonthEndProfitPanel({super.key, required this.snapshots});

  final List<BotProfitSnapshot> snapshots;

  @override
  State<MonthEndProfitPanel> createState() => _MonthEndProfitPanelState();
}

class _MonthStat {
  _MonthStat({required this.year, required this.month, required this.monthlyPnL});

  final int year;
  final int month;
  final double monthlyPnL;

  String get label => '$year-${month.toString().padLeft(2, '0')}';
}

class _MonthEndProfitPanelState extends State<MonthEndProfitPanel> {
  late DateTime _focusedMonth;

  @override
  void initState() {
    super.initState();
    _focusedMonth = _defaultFocusedMonth(widget.snapshots);
  }

  @override
  void didUpdateWidget(covariant MonthEndProfitPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshots.isEmpty && widget.snapshots.isNotEmpty) {
      _focusedMonth = _defaultFocusedMonth(widget.snapshots);
    }
  }

  static DateTime _defaultFocusedMonth(List<BotProfitSnapshot> snapshots) {
    final sorted = _sortedWithDates(snapshots);
    if (sorted.isEmpty) return DateTime(DateTime.now().year, DateTime.now().month);
    final last = _parseSnapshotAt(sorted.last.snapshotAt);
    if (last == null) return DateTime(DateTime.now().year, DateTime.now().month);
    return DateTime(last.year, last.month);
  }

  static List<BotProfitSnapshot> _sortedWithDates(List<BotProfitSnapshot> raw) {
    final withDates = <({DateTime d, BotProfitSnapshot s})>[];
    for (final s in raw) {
      final d = _parseSnapshotAt(s.snapshotAt);
      if (d != null) withDates.add((d: d, s: s));
    }
    withDates.sort((a, b) => a.d.compareTo(b.d));
    return withDates.map((e) => e.s).toList();
  }

  static double _equityAtOrBefore(List<BotProfitSnapshot> sorted, DateTime instant) {
    double? eq;
    for (final s in sorted) {
      final d = _parseSnapshotAt(s.snapshotAt);
      if (d == null) continue;
      if (!d.isAfter(instant)) {
        eq = s.equityUsdt;
      } else {
        break;
      }
    }
    return eq ?? double.nan;
  }

  static double _equityStrictlyBefore(List<BotProfitSnapshot> sorted, DateTime instant) {
    double? eq;
    for (final s in sorted) {
      final d = _parseSnapshotAt(s.snapshotAt);
      if (d == null) continue;
      if (d.isBefore(instant)) {
        eq = s.equityUsdt;
      } else {
        break;
      }
    }
    return eq ?? double.nan;
  }

  static List<_MonthStat> _computeMonthly(List<BotProfitSnapshot> sorted) {
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
      double startEq = sorted.first.initialBalance;
      for (final s in sorted) {
        final d = _parseSnapshotAt(s.snapshotAt);
        if (d == null) continue;
        if (d.isBefore(firstDay)) {
          startEq = s.equityUsdt;
        } else {
          break;
        }
      }
      double endEq = double.nan;
      for (final s in sorted) {
        final d = _parseSnapshotAt(s.snapshotAt);
        if (d != null && d.year == y && d.month == m) {
          endEq = s.equityUsdt;
        }
      }
      if (endEq.isFinite) {
        out.add(_MonthStat(year: y, month: m, monthlyPnL: endEq - startEq));
      }
    }
    return out;
  }

  Map<int, double> _dailyPnLForFocusedMonth(List<BotProfitSnapshot> sorted) {
    final y = _focusedMonth.year;
    final m = _focusedMonth.month;
    final lastDay = DateTime(y, m + 1, 0).day;
    final map = <int, double>{};
    for (var day = 1; day <= lastDay; day++) {
      final dayStart = DateTime(y, m, day);
      final dayEnd = DateTime(y, m, day, 23, 59, 59, 999);
      var eod = _equityAtOrBefore(sorted, dayEnd);
      var sod = _equityStrictlyBefore(sorted, dayStart);
      if (!eod.isFinite) continue;
      if (!sod.isFinite) sod = sorted.first.initialBalance;
      final pnl = eod - sod;
      if (pnl != 0 || _hasSnapshotOnDay(sorted, dayStart, dayEnd)) {
        map[day] = pnl;
      }
    }
    return map;
  }

  static bool _hasSnapshotOnDay(
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

  @override
  Widget build(BuildContext context) {
    final sorted = _sortedWithDates(widget.snapshots);
    final monthly = _computeMonthly(sorted);
    final daily = _dailyPnLForFocusedMonth(sorted);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '月底收益统计',
          style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
            color: AppFinanceStyle.labelColor,
            fontSize: (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 4,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '按自然月汇总：当月最后一条快照权益相对上月末（或期初）的变化（USDT）。',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
        ),
        const SizedBox(height: 16),
        if (monthly.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '暂无历史快照，无法统计月度收益',
              style: TextStyle(color: AppFinanceStyle.labelColor, fontSize: 13),
            ),
          )
        else ...[
          SizedBox(
            height: 200,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: _barMaxY(monthly),
                minY: _barMinY(monthly),
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
                      reservedSize: 40,
                      getTitlesWidget: (v, m) => Text(
                        v.toStringAsFixed(0),
                        style: TextStyle(
                          color: AppFinanceStyle.labelColor.withValues(alpha: 0.85),
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      getTitlesWidget: (v, m) {
                        final i = v.round();
                        if (i < 0 || i >= monthly.length) return const SizedBox.shrink();
                        final label = monthly[i].label;
                        final short = label.length >= 7 ? label.substring(2) : label;
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            short,
                            style: TextStyle(
                              color: AppFinanceStyle.labelColor.withValues(alpha: 0.9),
                              fontSize: 9,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < monthly.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: monthly[i].monthlyPnL,
                          width: 14,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                          color: monthly[i].monthlyPnL >= 0
                              ? AppFinanceStyle.profitGreenEnd
                              : Colors.red.withValues(alpha: 0.85),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                '日历（日权益变化）',
                style: (Theme.of(context).textTheme.titleMedium ?? const TextStyle()).copyWith(
                  color: AppFinanceStyle.labelColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.chevron_left, color: AppFinanceStyle.valueColor),
                onPressed: () {
                  setState(() {
                    _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
                  });
                },
              ),
              Text(
                '${_focusedMonth.year}年${_focusedMonth.month}月',
                style: const TextStyle(
                  color: AppFinanceStyle.valueColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, color: AppFinanceStyle.valueColor),
                onPressed: () {
                  setState(() {
                    _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          _CalendarGrid(
            year: _focusedMonth.year,
            month: _focusedMonth.month,
            dailyPnL: daily,
          ),
        ],
      ],
    );
  }

  static double _barMaxY(List<_MonthStat> monthly) {
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

  static double _barMinY(List<_MonthStat> monthly) {
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
}

class _CalendarGrid extends StatelessWidget {
  const _CalendarGrid({
    required this.year,
    required this.month,
    required this.dailyPnL,
  });

  final int year;
  final int month;
  final Map<int, double> dailyPnL;

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
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        for (var r = 0; r < cells.length / 7; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Expanded(child: cells[r * 7 + c] ?? const SizedBox(height: 44)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dayCell(BuildContext context, int day) {
    final pnl = dailyPnL[day];
    final has = pnl != null;
    final bg = !has
        ? Colors.white.withValues(alpha: 0.04)
        : (pnl >= 0
              ? AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.22)
              : Colors.red.withValues(alpha: 0.2));
    final fg = !has
        ? AppFinanceStyle.labelColor.withValues(alpha: 0.5)
        : (pnl >= 0 ? AppFinanceStyle.profitGreenEnd : Colors.redAccent);

    return Container(
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '$day',
            style: TextStyle(
              color: AppFinanceStyle.valueColor.withValues(alpha: 0.95),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (has)
            Text(
              pnl.abs() >= 1000
                  ? '${pnl >= 0 ? '+' : ''}${(pnl / 1000).toStringAsFixed(1)}k'
                  : '${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(0)}',
              style: TextStyle(color: fg, fontSize: 9, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
