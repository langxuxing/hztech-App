import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../widgets/water_background.dart';

/// 与 [WebTradingBotControlScreen._robotRuntime] / 时间格式化一致。
DateTime? _parseBackendTime(String? s) {
  if (s == null || s.isEmpty) return null;
  var d = DateTime.tryParse(s);
  if (d != null) return d;
  if (s.contains(' ') && !s.contains('T')) {
    return DateTime.tryParse(s.replaceFirst(' ', 'T'));
  }
  return null;
}

String _fmtDateTimeShort(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  final d = _parseBackendTime(iso);
  if (d == null) return iso;
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final min = d.minute.toString().padLeft(2, '0');
  return '$mm-$dd $hh:$min';
}

String _fmtDaysHours(Duration d) {
  if (d.isNegative) return '—';
  final tm = d.inMinutes;
  if (tm < 1) return '0 小时';
  final totalH = tm ~/ 60;
  final m = tm % 60;
  if (totalH < 24) {
    if (totalH < 1) return '$tm 分钟';
    if (m == 0) return '$totalH 小时';
    return '$totalH 小时 $m 分钟';
  }
  final days = totalH ~/ 24;
  final h = totalH % 24;
  if (h == 0) return '$days 天';
  return '$days 天 $h 小时';
}

/// 根据 strategy_events（降序）推断本次进程会话启动时间与运行时长。
({String robotStart, String robotDuration}) _robotRuntime(
  List<StrategyEvent> eventsDesc,
  bool running,
) {
  if (eventsDesc.isEmpty) {
    return (robotStart: '—', robotDuration: '—');
  }
  final asc = eventsDesc.reversed.toList();
  var lastStopIdx = -1;
  for (var i = 0; i < asc.length; i++) {
    if (asc[i].eventType == 'stop') lastStopIdx = i;
  }

  if (running) {
    String? startRaw;
    for (var i = lastStopIdx + 1; i < asc.length; i++) {
      final et = asc[i].eventType;
      if (et == 'start' || et == 'restart') {
        startRaw = asc[i].createdAt;
      }
    }
    if (startRaw == null || startRaw.isEmpty) {
      return (robotStart: '—', robotDuration: '—');
    }
    final parsed = _parseBackendTime(startRaw);
    if (parsed == null) {
      return (robotStart: '—', robotDuration: '—');
    }
    return (
      robotStart: _fmtDateTimeShort(startRaw),
      robotDuration: _fmtDaysHours(DateTime.now().difference(parsed)),
    );
  }

  if (lastStopIdx < 0) {
    return (robotStart: '—', robotDuration: '—');
  }
  final stopRaw = asc[lastStopIdx].createdAt;
  final stopParsed = _parseBackendTime(stopRaw);
  String? startRaw;
  for (var i = lastStopIdx - 1; i >= 0; i--) {
    final et = asc[i].eventType;
    if (et == 'start' || et == 'restart') {
      startRaw = asc[i].createdAt;
      break;
    }
  }
  if (startRaw == null || stopParsed == null) {
    return (robotStart: '—', robotDuration: '—');
  }
  final startParsed = _parseBackendTime(startRaw);
  if (startParsed == null) {
    return (robotStart: '—', robotDuration: '—');
  }
  return (
    robotStart: _fmtDateTimeShort(startRaw),
    robotDuration: _fmtDaysHours(stopParsed.difference(startParsed)),
  );
}

/// 交易机器人：列表来自 main.py /api/tradingbots（Account_List.json），
/// 启停走 script_file（如 tradingbot_ctrl/moneyflow_alangsandbox.sh start|stop）。
class TradingBotControl extends StatefulWidget {
  const TradingBotControl({super.key, this.embedInShell = false});

  /// 嵌入 Web 主导航壳时不显示本页 [AppBar]，避免与壳重复。
  final bool embedInShell;

  @override
  State<TradingBotControl> createState() => _TradingBotControlState();
}

class _TradingBotControlState extends State<TradingBotControl> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _list = [];
  Map<String, List<StrategyEvent>> _eventsByBot = {};
  bool _loading = true;
  String? _error;
  String? _loadingBotId;
  Timer? _runtimeTickTimer;

  void _scheduleRuntimeTick() {
    _runtimeTickTimer?.cancel();
    final anyRunning = _list.any(
      (b) => b.status == 'running' || b.isRunning == true,
    );
    if (!anyRunning || !mounted) return;
    _runtimeTickTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final botsResp = await api.getTradingBots();
      final bots = botsResp.botList;
      if (!mounted) return;
      setState(() {
        _list = bots;
        _loading = false;
      });
      try {
        final eventFutures = bots.map(
          (b) => api.getTradingbotEvents(b.tradingbotId, limit: 100),
        );
        final eventResults = await Future.wait(eventFutures);
        if (!mounted) return;
        final Map<String, List<StrategyEvent>> map = {};
        for (var i = 0; i < bots.length && i < eventResults.length; i++) {
          map[bots[i].tradingbotId] = eventResults[i].events;
        }
        setState(() {
          _eventsByBot = map;
        });
        _scheduleRuntimeTick();
      } catch (_) {
        // 列表已显示，事件失败时保留空映射
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 与 Web 端一致：停止前二次确认。
  void _onTapStop(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    if (!running) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认停止'),
        content: const Text('确定要停止该账户策略吗？此操作将终止当前运行，请确认以防误操作。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppFinanceStyle.textLoss,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _doStop(bot);
            },
            child: const Text('确定停止'),
          ),
        ],
      ),
    );
  }

  void _onTapStart(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    if (running) return;
    _doStart(bot);
  }

  Future<void> _doStart(UnifiedTradingBot bot) async {
    setState(() => _loadingBotId = bot.tradingbotId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.startBot(bot.tradingbotId);
      if (!mounted) return;
      setState(() => _loadingBotId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(resp.success ? '启动成功' : (resp.message ?? '启动失败')),
        ),
      );
      if (resp.success) _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingBotId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请求失败: $e')));
    }
  }

  Future<void> _doStop(UnifiedTradingBot bot) async {
    setState(() => _loadingBotId = bot.tradingbotId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.stopBot(bot.tradingbotId);
      if (!mounted) return;
      setState(() => _loadingBotId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(resp.success ? '停止成功' : (resp.message ?? '停止失败')),
        ),
      );
      if (resp.success) _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingBotId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请求失败: $e')));
    }
  }

  static const _barBg = AppFinanceStyle.backgroundDark;
  static const _barTextColor = AppFinanceStyle.valueColor;

  static bool _botErrored(UnifiedTradingBot b) {
    final s = b.status.toLowerCase();
    return s.contains('error') || s == 'failed' || s.contains('exception');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _runtimeTickTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: widget.embedInShell
          ? null
          : AppBar(
              title: Text(
                '策略启停',
                style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  color: _barTextColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              backgroundColor: _barBg,
              foregroundColor: _barTextColor,
              surfaceTintColor: Colors.transparent,
            ),
      body: WaterBackground(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading && _list.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _list.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _list.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 64,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '暂无交易账户',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '请检查账户配置或下拉刷新',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                  itemCount: _list.length,
                  itemBuilder: (context, i) {
                    final bot = _list[i];
                    final running =
                        bot.status == 'running' || bot.isRunning == true;
                    final events = _eventsByBot[bot.tradingbotId] ?? [];
                    final robot = _robotRuntime(events, running);
                    final metaStyle =
                        AppFinanceStyle.valueTextStyle(
                          context,
                          fontSize: 13,
                        ).copyWith(
                          color: AppFinanceStyle.labelColor.withValues(
                            alpha: 0.88,
                          ),
                          fontWeight: FontWeight.w600,
                        );
                    final durationStyle =
                        AppFinanceStyle.valueTextStyle(
                          context,
                          fontSize: 16,
                        ).copyWith(
                          fontWeight: FontWeight.w600,
                          color: AppFinanceStyle.textDefault.withValues(
                            alpha: 0.72,
                          ),
                          letterSpacing: 0.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        );
                    final kickoffLabelStyle =
                        AppFinanceStyle.labelTextStyle(context).copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppFinanceStyle.labelColor.withValues(
                            alpha: 0.48,
                          ),
                        );
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: FinanceCard(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          bot.tradingbotName ??
                                              bot.tradingbotId,
                                          style:
                                              (Theme.of(
                                                        context,
                                                      ).textTheme.titleLarge ??
                                                      const TextStyle())
                                                  .copyWith(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize:
                                                        (Theme.of(context)
                                                                .textTheme
                                                                .titleLarge
                                                                ?.fontSize ??
                                                            22) +
                                                        2,
                                                    color: AppFinanceStyle
                                                        .valueColor,
                                                  ),
                                        ),
                                      ),
                                      if (bot.isTest) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.orange.withValues(
                                              alpha: 0.3,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            '测试',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall
                                                ?.copyWith(
                                                  color: AppFinanceStyle
                                                      .textDefault,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  if (!bot.canControl) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      '未配置 accounts 目录下的启停脚本（script_file）',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.outline,
                                          ),
                                    ),
                                  ],
                                  if (bot.symbol != null &&
                                      bot.symbol!.isNotEmpty) ...[
                                    const SizedBox(height: 14),

                                    Text(
                                      '交易对 ${bot.symbol}',
                                      style: AppFinanceStyle.labelTextStyle(
                                        context,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 14),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      Text('启动时间', style: kickoffLabelStyle),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          robot.robotStart,
                                          style: metaStyle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      Text('已运行:', style: kickoffLabelStyle),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          robot.robotDuration,
                                          style: durationStyle,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                _RunStatusChip(
                                  running: running,
                                  errored: _botErrored(bot),
                                ),
                                SizedBox(height: 24),
                                if (bot.canControl)
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        const SizedBox(height: 10),
                                        _buildStrategyStartStopColumn(bot),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  /// 与 [WebTradingBotControlScreen] 机器人区一致：独立「启动」「停止」两键；进行中两键均显示加载且不可点。
  /// 右侧竖向排列。
  Widget _buildStrategyStartStopColumn(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    final busy = _loadingBotId == bot.tradingbotId;
    const size = 48.0;
    const iconSize = 26.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _strategyCircleAction(
          size: size,
          iconSize: iconSize,
          accent: AppFinanceStyle.textProfit,
          icon: Icons.play_circle_outline,
          busy: busy,
          enabled: !busy && !running,
          onTap: () => _onTapStart(bot),
        ),
        const SizedBox(width: 12),
        _strategyCircleAction(
          size: size,
          iconSize: iconSize,
          accent: AppFinanceStyle.textLoss,
          icon: Icons.stop_circle_outlined,
          busy: busy,
          enabled: !busy && running,
          onTap: () => _onTapStop(bot),
        ),
      ],
    );
  }

  Widget _strategyCircleAction({
    required double size,
    required double iconSize,
    required Color accent,
    required IconData icon,
    required bool busy,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final canTap = enabled && !busy;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canTap ? onTap : null,
        borderRadius: BorderRadius.circular(size),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: accent.withValues(alpha: canTap ? 0.55 : 0.2),
              width: 1.5,
            ),
            color: accent.withValues(alpha: canTap ? 0.12 : 0.04),
          ),
          child: busy
              ? SizedBox(
                  width: iconSize,
                  height: iconSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: accent.withValues(alpha: 0.85),
                  ),
                )
              : Icon(
                  icon,
                  size: iconSize,
                  color: canTap ? accent : accent.withValues(alpha: 0.35),
                ),
        ),
      ),
    );
  }
}

/// 右上角运行状态角标（与 Web 卡片区语义一致）。
class _RunStatusChip extends StatelessWidget {
  const _RunStatusChip({required this.running, required this.errored});

  final bool running;
  final bool errored;

  Color get _accent {
    if (errored) return AppFinanceStyle.textLoss;
    if (running) return AppFinanceStyle.textProfit;
    return AppFinanceStyle.textDefault;
  }

  String get _label {
    if (errored) return '异常';
    if (running) return '运行中';
    return '已停止';
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: accent.withValues(alpha: 0.16),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppFinanceStyle.textProfit.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            _label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: accent,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.35,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
