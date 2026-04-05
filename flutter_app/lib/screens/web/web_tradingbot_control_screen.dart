import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';
import 'web_account_profit_screen.dart';

/// Web「策略启停」：与侧栏 [WebMainShell] 一致；多列玻璃卡网格，赛季 + 机器人会话时长 + 启停/重启。
/// 账户级资金曲线与汇总见侧栏「账号总览」[WebDashboardScreen]。
class WebTradingBotControlScreen extends StatefulWidget {
  const WebTradingBotControlScreen({super.key, this.sharedBots = const []});

  final List<UnifiedTradingBot> sharedBots;

  @override
  State<WebTradingBotControlScreen> createState() =>
      _WebTradingBotControlScreenState();
}

class _WebTradingBotControlScreenState
    extends State<WebTradingBotControlScreen> {
  final _prefs = SecurePrefs();
  List<AccountProfit> _accounts = [];
  Map<String, List<BotSeason>> _seasonsByBot = {};
  Map<String, List<StrategyEvent>> _eventsByBot = {};
  bool _loading = true;
  String? _error;
  String? _loadingBotId;
  String? _seasonLoadingBotId;
  bool _bulkBusy = false;

  static const _dashPlaceholder = '—';

  /// 无赛季/进程时长时用 00:00:00 占位，便于对齐。
  static String _durationOrPlaceholder(String s) =>
      s == _dashPlaceholder ? '00:00:00' : s;

  static bool _hasOpenSeason(List<BotSeason> seasons) {
    for (final s in seasons) {
      final st = s.stoppedAt;
      if (st == null || st.isEmpty) return true;
    }
    return false;
  }

  /// 兼容 ISO8601 与 SQLite `YYYY-MM-DD HH:MM:SS`。
  static DateTime? _parseBackendTime(String? s) {
    if (s == null || s.isEmpty) return null;
    var d = DateTime.tryParse(s);
    if (d != null) return d;
    if (s.contains(' ') && !s.contains('T')) {
      return DateTime.tryParse(s.replaceFirst(' ', 'T'));
    }
    return null;
  }

  static String _fmtDateTimeShort(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final d = _parseBackendTime(iso);
    if (d == null) return iso;
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$min';
  }

  /// 展示为「X 天 Y 小时」；不足 1 小时时用分钟。
  static String _fmtDaysHours(Duration d) {
    if (d.isNegative) return '—';
    if (d.inMinutes < 1) return '0 天 0 小时';
    if (d.inHours < 1) return '0 天 ${d.inMinutes} 分钟';
    final totalHours = d.inHours;
    final days = totalHours ~/ 24;
    final hours = totalHours % 24;
    return '$days 天 $hours 小时';
  }

  /// 当前/最近一条赛季的启动时间与运行时长（天+小时）。
  static ({String seasonStart, String seasonDuration}) _seasonRuntime(
    List<BotSeason> seasons,
    bool running,
  ) {
    if (seasons.isEmpty) {
      return (seasonStart: '—', seasonDuration: '—');
    }
    BotSeason? open;
    for (final s in seasons) {
      final st = s.stoppedAt;
      if (st == null || st.isEmpty) {
        open = s;
        break;
      }
    }
    if (running && open != null) {
      final start = open.startedAt;
      final parsed = start != null && start.isNotEmpty
          ? _parseBackendTime(start)
          : null;
      if (parsed == null) {
        return (seasonStart: '—', seasonDuration: '—');
      }
      return (
        seasonStart: _fmtDateTimeShort(start),
        seasonDuration: _fmtDaysHours(DateTime.now().difference(parsed)),
      );
    }
    final last = seasons.first;
    final start = last.startedAt;
    final stop = last.stoppedAt;
    final ps = start != null && start.isNotEmpty
        ? _parseBackendTime(start)
        : null;
    final pe = stop != null && stop.isNotEmpty ? _parseBackendTime(stop) : null;
    if (ps == null) {
      return (seasonStart: '—', seasonDuration: '—');
    }
    if (pe != null) {
      return (
        seasonStart: _fmtDateTimeShort(start),
        seasonDuration: _fmtDaysHours(pe.difference(ps)),
      );
    }
    if (running) {
      return (
        seasonStart: _fmtDateTimeShort(start),
        seasonDuration: _fmtDaysHours(DateTime.now().difference(ps)),
      );
    }
    return (seasonStart: _fmtDateTimeShort(start), seasonDuration: '—');
  }

  /// 根据 strategy_events（降序）推断本次进程会话启动时间与运行时长。
  static ({String robotStart, String robotDuration}) _robotRuntime(
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final profitResp = await api.getAccountProfit();
      final accounts = profitResp.accounts ?? [];
      final Map<String, List<BotSeason>> seasonsMap = {};
      final Map<String, List<StrategyEvent>> eventsMap = {};
      try {
        final ids = accounts
            .map((a) => a.botId)
            .where((id) => id.isNotEmpty)
            .toList();
        if (ids.isNotEmpty) {
          final bundled = await Future.wait([
            Future.wait(
              ids.map((id) => api.getTradingbotSeasons(id, limit: 30)),
            ),
            Future.wait(
              ids.map((id) => api.getTradingbotEvents(id, limit: 100)),
            ),
          ]);
          final seasonResults = bundled[0] as List<TradingbotSeasonsResponse>;
          final eventResults = bundled[1] as List<TradingbotEventsResponse>;
          for (var i = 0; i < ids.length; i++) {
            if (i < seasonResults.length) {
              seasonsMap[ids[i]] = seasonResults[i].seasons;
            }
            if (i < eventResults.length) {
              eventsMap[ids[i]] = eventResults[i].events;
            }
          }
        }
      } catch (_) {
        // 卡片仍显示，赛季/事件失败时为空
      }
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _seasonsByBot = seasonsMap;
        _eventsByBot = eventsMap;
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

  UnifiedTradingBot? _botFor(AccountProfit a) {
    for (final b in widget.sharedBots) {
      if (b.tradingbotId == a.botId) return b;
    }
    return null;
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

  Future<void> _doRestart(UnifiedTradingBot bot) async {
    setState(() => _loadingBotId = bot.tradingbotId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.restartBot(bot.tradingbotId);
      if (!mounted) return;
      setState(() => _loadingBotId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(resp.success ? '重启已执行' : (resp.message ?? '重启失败')),
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
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
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

  Future<void> _doSeasonStart(UnifiedTradingBot bot) async {
    setState(() => _seasonLoadingBotId = bot.tradingbotId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.seasonStartBot(bot.tradingbotId);
      if (!mounted) return;
      setState(() => _seasonLoadingBotId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(resp.success ? '赛季已启动' : (resp.message ?? '赛季启动失败')),
        ),
      );
      if (resp.success) _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _seasonLoadingBotId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请求失败: $e')));
    }
  }

  Future<void> _doSeasonStop(UnifiedTradingBot bot) async {
    setState(() => _seasonLoadingBotId = bot.tradingbotId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.seasonStopBot(bot.tradingbotId);
      if (!mounted) return;
      setState(() => _seasonLoadingBotId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(resp.success ? '赛季已停止' : (resp.message ?? '赛季停止失败')),
        ),
      );
      if (resp.success) _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _seasonLoadingBotId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请求失败: $e')));
    }
  }

  void _onTapSeasonStop(UnifiedTradingBot bot) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认结束赛季'),
        content: const Text('确定要结束当前盈利赛季吗？将按当前权益结算本赛季。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange),
            onPressed: () {
              Navigator.pop(ctx);
              _doSeasonStop(bot);
            },
            child: const Text('确定结束'),
          ),
        ],
      ),
    );
  }

  bool _isBotRunning(UnifiedTradingBot? b) =>
      b != null && (b.status == 'running' || b.isRunning == true);

  bool _isBotError(UnifiedTradingBot? b) {
    if (b == null) return false;
    final s = b.status.toLowerCase();
    return s.contains('error') ||
        s == 'failed' ||
        s.contains('exception');
  }

  ({int total, int running, int stopped, int error}) _aggregateStats() {
    var running = 0, stopped = 0, err = 0;
    for (final a in _accounts) {
      final bot = _botFor(a);
      if (_isBotError(bot)) {
        err++;
      } else if (_isBotRunning(bot)) {
        running++;
      } else {
        stopped++;
      }
    }
    return (total: _accounts.length, running: running, stopped: stopped, error: err);
  }

  List<UnifiedTradingBot> _controllableBots() => _accounts
      .map(_botFor)
      .whereType<UnifiedTradingBot>()
      .where((b) => b.canControl)
      .toList();

  Future<void> _bulkStartAll() async {
    if (_bulkBusy) return;
    final targets =
        _controllableBots().where((b) => !_isBotRunning(b)).toList();
    if (targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有处于停止状态且可管控的账户')),
        );
      }
      return;
    }
    final go =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('全部启动'),
            content: Text('将依次启动 ${targets.length} 个机器人进程，是否继续？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定'),
              ),
            ],
          ),
        ) ??
        false;
    if (!go || !mounted) return;
    setState(() => _bulkBusy = true);
    var ok = 0;
    for (final bot in targets) {
      try {
        final baseUrl = await _prefs.backendBaseUrl;
        final token = await _prefs.authToken;
        final api = ApiClient(baseUrl, token: token);
        final resp = await api.startBot(bot.tradingbotId);
        if (resp.success) ok++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _bulkBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('批量启动完成：成功 $ok / ${targets.length}')),
    );
    _load();
  }

  Future<void> _bulkStopAll() async {
    if (_bulkBusy) return;
    final targets = _controllableBots().where(_isBotRunning).toList();
    if (targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前没有运行中的可管控账户')),
        );
      }
      return;
    }
    final go =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('全部停止'),
            content: Text('将依次停止 ${targets.length} 个机器人进程，是否继续？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定'),
              ),
            ],
          ),
        ) ??
        false;
    if (!go || !mounted) return;
    setState(() => _bulkBusy = true);
    var ok = 0;
    for (final bot in targets) {
      try {
        final baseUrl = await _prefs.backendBaseUrl;
        final token = await _prefs.authToken;
        final api = ApiClient(baseUrl, token: token);
        final resp = await api.stopBot(bot.tradingbotId);
        if (resp.success) ok++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _bulkBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('批量停止完成：成功 $ok / ${targets.length}')),
    );
    _load();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _openAccount(AccountProfit a) {
    final id = a.botId.isNotEmpty ? a.botId : null;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => WebAccountProfitScreen(
          sharedBots: widget.sharedBots,
          initialBotId: id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = _aggregateStats();
    const techBase = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF0B1528),
        Color(0xFF0A0F18),
        AppFinanceStyle.backgroundDark,
      ],
    );

    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        baseGradient: techBase,
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _load,
              child: _loading && _accounts.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null && _accounts.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.25,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: _load,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '策略启停',
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        color: AppFinanceStyle.valueColor,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.5,
                                      ),
                                ),
                                const SizedBox(height: 14),
                                _GlobalBotStatsBar(
                                  total: stats.total,
                                  running: stats.running,
                                  stopped: stats.stopped,
                                  errorCount: stats.error,
                                  bulkBusy: _bulkBusy,
                                  onBulkStart: _bulkStartAll,
                                  onBulkStop: _bulkStopAll,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_accounts.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Center(
                                child: Text(
                                  '暂无账户数据',
                                  style: AppFinanceStyle.labelTextStyle(context),
                                ),
                              ),
                            ),
                          )
                        else
                          Builder(
                            builder: (context) {
                              final w = MediaQuery.sizeOf(context).width;
                              var cross = 1;
                              if (w >= 1200) {
                                cross = 4;
                              } else if (w >= 800) {
                                cross = 3;
                              }
                              return SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: cross,
                                      mainAxisSpacing: 28,
                                      crossAxisSpacing: 28,
                                      childAspectRatio: cross >= 3 ? 0.9 : 0.78,
                                    ),
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final a = _accounts[index];
                                  final bot = _botFor(a);
                                  final seasons =
                                      _seasonsByBot[a.botId] ?? const [];
                                  final events =
                                      _eventsByBot[a.botId] ?? const [];
                                  final running =
                                      bot != null &&
                                      (bot.status == 'running' ||
                                          bot.isRunning == true);
                                  final season = _seasonRuntime(
                                    seasons,
                                    running,
                                  );
                                  final robot = _robotRuntime(
                                    events,
                                    running,
                                  );
                                  final openSeason = _hasOpenSeason(seasons);
                                  return _AccountGlassCard(
                                    account: a,
                                    bot: bot,
                                    seasonStart: season.seasonStart,
                                    seasonDuration: _durationOrPlaceholder(
                                      season.seasonDuration,
                                    ),
                                    robotStart: robot.robotStart,
                                    robotDuration: _durationOrPlaceholder(
                                      robot.robotDuration,
                                    ),
                                    hasOpenSeason: openSeason,
                                    robotLoadingBotId: _loadingBotId,
                                    seasonLoadingBotId: _seasonLoadingBotId,
                                    onStart: bot != null && bot.canControl
                                        ? () => _doStart(bot)
                                        : null,
                                    onStop: bot != null && bot.canControl
                                        ? () => _onTapStop(bot)
                                        : null,
                                    onRestart: bot != null && bot.canControl
                                        ? () => _doRestart(bot)
                                        : null,
                                    onSeasonStart: bot != null && bot.canControl
                                        ? () => _doSeasonStart(bot)
                                        : null,
                                    onSeasonStop: bot != null && bot.canControl
                                        ? () => _onTapSeasonStop(bot)
                                        : null,
                                    onOpenDetail: () => _openAccount(a),
                                  );
                                }, childCount: _accounts.length),
                              );
                            },
                          ),
                        const SliverPadding(
                          padding: EdgeInsets.only(bottom: 48),
                        ),
                      ],
                    ),
            ),
            if (_bulkBusy)
              Positioned.fill(
                child: AbsorbPointer(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.25),
                    alignment: Alignment.center,
                    child: const Card(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 14),
                            Text('批量操作中…'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 顶部全局统计与一键启停。
class _GlobalBotStatsBar extends StatelessWidget {
  const _GlobalBotStatsBar({
    required this.total,
    required this.running,
    required this.stopped,
    required this.errorCount,
    required this.bulkBusy,
    required this.onBulkStart,
    required this.onBulkStop,
  });

  final int total;
  final int running;
  final int stopped;
  final int errorCount;
  final bool bulkBusy;
  final VoidCallback onBulkStart;
  final VoidCallback onBulkStop;

  static const _cyan = Color(0xFF2EE6D6);

  @override
  Widget build(BuildContext context) {
    final label = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppFinanceStyle.labelColor.withValues(alpha: 0.85),
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        );
    final chipText = Theme.of(context).textTheme.titleSmall?.copyWith(
          color: AppFinanceStyle.valueColor,
          fontWeight: FontWeight.w800,
        );

    Widget chip(String title, String value, Color accent) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accent.withValues(alpha: 0.35),
          ),
          gradient: LinearGradient(
            colors: [
              accent.withValues(alpha: 0.12),
              Colors.white.withValues(alpha: 0.04),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: label),
            const SizedBox(height: 2),
            Text(value, style: chipText?.copyWith(color: accent)),
          ],
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
          ),
          gradient: LinearGradient(
            colors: [
              const Color(0xFF151B2E).withValues(alpha: 0.92),
              const Color(0xFF101520).withValues(alpha: 0.88),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < 720;
              final statsRow = Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  chip('总计', '$total', _cyan),
                  chip('运行中', '$running', const Color(0xFF3DFF9C)),
                  chip('已停止', '$stopped', const Color(0xFF8B94A8)),
                  if (errorCount > 0)
                    chip('异常', '$errorCount', const Color(0xFFFFA726)),
                ],
              );
              final actions = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: bulkBusy ? null : onBulkStart,
                    style: FilledButton.styleFrom(
                      foregroundColor: const Color(0xFF3DFF9C),
                      backgroundColor: const Color(0xFF3DFF9C).withValues(
                        alpha: 0.14,
                      ),
                    ),
                    icon: const Icon(Icons.play_circle_outline, size: 20),
                    label: const Text('全部启动'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.tonalIcon(
                    onPressed: bulkBusy ? null : onBulkStop,
                    style: FilledButton.styleFrom(
                      foregroundColor: const Color(0xFFFF8A80),
                      backgroundColor: const Color(0xFFFF8A80).withValues(
                        alpha: 0.12,
                      ),
                    ),
                    icon: const Icon(Icons.stop_circle_outlined, size: 20),
                    label: const Text('全部停止'),
                  ),
                ],
              );

              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    statsRow,
                    const SizedBox(height: 12),
                    actions,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: statsRow),
                  actions,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AccountGlassCard extends StatefulWidget {
  const _AccountGlassCard({
    required this.account,
    required this.bot,
    required this.seasonStart,
    required this.seasonDuration,
    required this.robotStart,
    required this.robotDuration,
    required this.hasOpenSeason,
    required this.robotLoadingBotId,
    required this.seasonLoadingBotId,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
    required this.onSeasonStart,
    required this.onSeasonStop,
    required this.onOpenDetail,
  });

  final AccountProfit account;
  final UnifiedTradingBot? bot;
  final String seasonStart;
  final String seasonDuration;
  final String robotStart;
  final String robotDuration;
  final bool hasOpenSeason;
  final String? robotLoadingBotId;
  final String? seasonLoadingBotId;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onRestart;
  final VoidCallback? onSeasonStart;
  final VoidCallback? onSeasonStop;
  final VoidCallback onOpenDetail;

  @override
  State<_AccountGlassCard> createState() => _AccountGlassCardState();
}

class _AccountGlassCardState extends State<_AccountGlassCard>
    with SingleTickerProviderStateMixin {
  static const _labelMuted = AppFinanceStyle.labelColor;
  static const _cyanAccent = Color(0xFF2EE6D6);
  static const _greenRun = Color(0xFF3DFF9C);
  static const _redStop = Color(0xFFFF8A80);
  static const _blueRestart = Color(0xFF4FC3F7);

  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _AccountGlassCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    final run = _running;
    if (run) {
      if (!_pulse.isAnimating) {
        _pulse.repeat(reverse: true);
      }
    } else {
      _pulse.stop();
      _pulse.reset();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  bool get _running =>
      widget.bot != null &&
      (widget.bot!.status == 'running' || widget.bot!.isRunning == true);

  bool get _errored {
    final b = widget.bot;
    if (b == null) return false;
    final s = b.status.toLowerCase();
    return s.contains('error') ||
        s == 'failed' ||
        s.contains('exception');
  }

  Color get _statusAccent {
    if (_errored) return const Color(0xFFFFA726);
    if (_running) return _greenRun;
    // 已停止：偏冷灰 + 极淡玫红倾向，与「运行中」绿对比更清晰
    return const Color(0xFF8B7D8C);
  }

  String get _statusLabel {
    if (_errored) return '异常';
    if (_running) return '运行中';
    return '已停止';
  }

  @override
  Widget build(BuildContext context) {
    final title =
        widget.bot?.tradingbotName ??
        (widget.account.exchangeAccount.isNotEmpty
            ? widget.account.exchangeAccount
            : widget.account.botId);
    final bid = widget.bot?.tradingbotId ?? widget.account.botId;
    final robotBusy = widget.robotLoadingBotId == bid;
    final seasonBusy = widget.seasonLoadingBotId == bid;
    final canCtl = widget.bot != null && widget.bot!.canControl;

    final titleStyle =
        (Theme.of(context).textTheme.titleMedium ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w800,
          fontSize: (Theme.of(context).textTheme.titleMedium?.fontSize ?? 20) + 1,
          color: AppFinanceStyle.valueColor,
          letterSpacing: 0.2,
        );

    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: _labelMuted.withValues(alpha: 0.62),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          fontSize: 11.5,
        );

    final kickoffLabelStyle = labelStyle?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: _labelMuted.withValues(alpha: 0.48),
          letterSpacing: 0.2,
        );

    final metaStyle = AppFinanceStyle.valueTextStyle(context, fontSize: 13).copyWith(
          color: _labelMuted.withValues(alpha: 0.88),
          fontWeight: FontWeight.w600,
        );

    final durationStyle = AppFinanceStyle.valueTextStyle(context, fontSize: 22).copyWith(
          fontWeight: FontWeight.w800,
          color: _cyanAccent,
          letterSpacing: 0.5,
          fontFeatures: const [FontFeature.tabularFigures()],
        );

    final glowT = _running ? _pulse.value : 0.0;

    final cardSurface = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        const Color(0xFF242830).withValues(alpha: 0.72),
        const Color(0xFF181C24).withValues(alpha: 0.58),
        const Color(0xFF141820).withValues(alpha: 0.52),
      ],
    );

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        return FinanceCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          statusAccent: _statusAccent,
          accentGlowT: _running ? glowT : 0,
          surfaceGradient: cardSurface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.max,
            children: [
              Row(
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
                                title,
                                style: titleStyle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (widget.bot?.isTest == true) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: const Color(0xFFFFB74D).withValues(
                                      alpha: 0.55,
                                    ),
                                  ),
                                  color: const Color(0xFFFFB74D).withValues(
                                    alpha: 0.12,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFFFFB74D).withValues(
                                        alpha: 0.22,
                                      ),
                                      blurRadius: 10,
                                      spreadRadius: -2,
                                    ),
                                  ],
                                ),
                                child: Text(
                                  '测试',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: const Color(0xFFFFE082),
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.3,
                                      ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (widget.bot != null && !widget.bot!.canControl) ...[
                          const SizedBox(height: 6),
                          Text(
                            '未配置 Accounts 目录下的启停脚本（script_file）',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outline,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: _statusAccent.withValues(alpha: 0.16),
                      border: Border.all(
                        color: _statusAccent.withValues(alpha: 0.5),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _statusAccent.withValues(
                            alpha: _running ? 0.12 + 0.2 * glowT : 0.06,
                          ),
                          blurRadius: _running ? 10 : 6,
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_running) ...[
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _greenRun.withValues(
                                alpha: 0.45 + 0.45 * glowT,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _greenRun.withValues(
                                    alpha: 0.35 * glowT,
                                  ),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 7),
                        ],
                        Text(
                          _statusLabel,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: _statusAccent,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.35,
                                fontSize: 12,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              Text('赛季控制', style: labelStyle),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text('启动 ', style: kickoffLabelStyle),
                        Expanded(
                          child: Text(
                            widget.seasonStart == '—'
                                ? '未记录'
                                : widget.seasonStart,
                            style: metaStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(widget.seasonDuration, style: durationStyle),
                ],
              ),
              const SizedBox(height: 12),

              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.white.withValues(alpha: 0.04),
                  border: Border.all(
                    color: _cyanAccent.withValues(alpha: 0.18),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '盈利赛季',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: _cyanAccent.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.35,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _CyberCircleIconButton(
                            size: 38,
                            iconSize: 20,
                            isLoading: seasonBusy,
                            enabled:
                                canCtl &&
                                !seasonBusy &&
                                widget.onSeasonStart != null,
                            icon: Icons.play_circle_outline,
                            accent: _greenRun,
                            onTap: widget.onSeasonStart,
                          ),
                          _CyberCircleIconButton(
                            size: 38,
                            iconSize: 20,
                            isLoading: seasonBusy,
                            enabled:
                                canCtl &&
                                !seasonBusy &&
                                widget.hasOpenSeason &&
                                widget.onSeasonStop != null,
                            icon: Icons.stop_circle_outlined,
                            accent: _redStop,
                            onTap: widget.onSeasonStop,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),
              Divider(
                height: 1,
                thickness: 1,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              const SizedBox(height: 12),

              Text('机器人启动', style: labelStyle),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text('启动 ', style: kickoffLabelStyle),
                        Expanded(
                          child: Text(
                            widget.robotStart == '—'
                                ? '未记录'
                                : widget.robotStart,
                            style: metaStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(widget.robotDuration, style: durationStyle),
                ],
              ),

              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: const Color(0xFF3DFF9C).withValues(alpha: 0.05),
                  border: Border.all(
                    color: AppFinanceStyle.profitGreenEnd.withValues(
                      alpha: 0.22,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '策略 · 进程控制',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: AppFinanceStyle.profitGreenEnd.withValues(
                                alpha: 0.95,
                              ),
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.35,
                            ),
                      ),
                      if (robotBusy) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: const LinearProgressIndicator(minHeight: 3),
                        ),
                      ] else if (_running) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            minHeight: 3,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.06,
                            ),
                            color: _greenRun.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      if (canCtl)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _CyberCircleIconButton(
                              size: 36,
                              iconSize: 18,
                              isLoading: robotBusy,
                              enabled: !robotBusy && !_running,
                              icon: Icons.play_circle_outline,
                              accent: _greenRun,
                              onTap: widget.onStart,
                            ),
                            _CyberCircleIconButton(
                              size: 36,
                              iconSize: 18,
                              isLoading: robotBusy,
                              enabled: !robotBusy && _running,
                              icon: Icons.stop_circle_outlined,
                              accent: _redStop,
                              onTap: widget.onStop,
                            ),
                            _CyberCircleIconButton(
                              size: 36,
                              iconSize: 18,
                              isLoading: robotBusy,
                              enabled: !robotBusy,
                              icon: Icons.restart_alt_outlined,
                              accent: _blueRestart,
                              onTap: widget.onRestart,
                            ),
                          ],
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
        );
      },
    );
  }
}

/// 极简描边圆钮：悬停/按下反馈 + 线性图标。
class _CyberCircleIconButton extends StatefulWidget {
  const _CyberCircleIconButton({
    required this.size,
    required this.iconSize,
    required this.isLoading,
    required this.enabled,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  final double size;
  final double iconSize;
  final bool isLoading;
  final bool enabled;
  final IconData icon;
  final Color accent;
  final VoidCallback? onTap;

  @override
  State<_CyberCircleIconButton> createState() => _CyberCircleIconButtonState();
}

class _CyberCircleIconButtonState extends State<_CyberCircleIconButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final canPress =
        widget.enabled && !widget.isLoading && widget.onTap != null;
    final a = widget.accent;
    final borderA = canPress
        ? (_pressed ? 0.95 : (_hover ? 0.75 : 0.4))
        : 0.15;
    final fillA = canPress
        ? (_pressed ? 0.22 : (_hover ? 0.14 : 0.08))
        : 0.04;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: canPress ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: widget.size,
          height: widget.size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: a.withValues(alpha: borderA), width: 1.5),
            color: a.withValues(alpha: fillA),
            boxShadow: canPress && (_hover || _pressed)
                ? [
                    BoxShadow(
                      color: a.withValues(alpha: _pressed ? 0.35 : 0.22),
                      blurRadius: _pressed ? 14 : 10,
                      spreadRadius: 0,
                    ),
                  ]
                : null,
          ),
          child: widget.isLoading
              ? SizedBox(
                  width: widget.iconSize,
                  height: widget.iconSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: a.withValues(alpha: 0.85),
                  ),
                )
              : Icon(
                  widget.icon,
                  size: widget.iconSize,
                  color: canPress
                      ? a
                      : a.withValues(alpha: 0.28),
                ),
        ),
      ),
    );
  }
}
