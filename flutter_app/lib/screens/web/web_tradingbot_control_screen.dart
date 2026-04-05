import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';
import 'web_account_profit_screen.dart';

/// Web「策略启动」：多列玻璃卡网格，展示赛季时间与启停/重启（与 [TradingBotControl] 同源 API）。
/// 全局资金概览见导航「仪表盘」[WebDashboardScreen]。
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
    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading && _accounts.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _accounts.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(height: MediaQuery.sizeOf(context).height * 0.25),
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
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      sliver: SliverToBoxAdapter(
                        child: Text(
                          '账户总数（${_accounts.length}）',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: AppFinanceStyle.valueColor,
                                fontWeight: FontWeight.w900,
                              ),
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
                                  mainAxisSpacing: 16,
                                  crossAxisSpacing: 16,
                                  childAspectRatio: cross >= 3 ? 0.92 : 0.82,
                                ),
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final a = _accounts[index];
                              final bot = _botFor(a);
                              final seasons =
                                  _seasonsByBot[a.botId] ?? const [];
                              final events = _eventsByBot[a.botId] ?? const [];
                              final running =
                                  bot != null &&
                                  (bot.status == 'running' ||
                                      bot.isRunning == true);
                              final season = _seasonRuntime(seasons, running);
                              final robot = _robotRuntime(events, running);
                              final openSeason = _hasOpenSeason(seasons);
                              return _AccountGlassCard(
                                account: a,
                                bot: bot,
                                seasonStart: season.seasonStart,
                                seasonDuration: season.seasonDuration,
                                robotStart: robot.robotStart,
                                robotDuration: robot.robotDuration,
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
                    const SliverPadding(padding: EdgeInsets.only(bottom: 48)),
                  ],
                ),
        ),
      ),
    );
  }
}

class _AccountGlassCard extends StatelessWidget {
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

  static const _labelColor = AppFinanceStyle.labelColor;
  static const _numberColor = AppFinanceStyle.profitGreenEnd;

  @override
  Widget build(BuildContext context) {
    final title =
        bot?.tradingbotName ??
        (account.exchangeAccount.isNotEmpty
            ? account.exchangeAccount
            : account.botId);
    final running =
        bot != null && (bot!.status == 'running' || bot!.isRunning == true);
    final bid = bot?.tradingbotId ?? account.botId;
    final robotBusy = robotLoadingBotId == bid;
    final seasonBusy = seasonLoadingBotId == bid;
    final canCtl = bot != null && bot!.canControl;

    final titleStyle =
        (Theme.of(context).textTheme.titleMedium ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w800,
          fontSize: (Theme.of(context).textTheme.titleMedium?.fontSize ?? 20),
          color: AppFinanceStyle.valueColor,
        );
    final valueStyle = AppFinanceStyle.valueTextStyle(
      context,
      fontSize: 16,
    ).copyWith(fontWeight: FontWeight.w700, letterSpacing: 0);

    final statusStyle = AppFinanceStyle.labelTextStyle(context).copyWith(
      color: running ? Colors.greenAccent : AppFinanceStyle.labelColor,
      fontWeight: FontWeight.w700,
    );

    return FinanceCard(
      padding: const EdgeInsets.all(16),
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
                        if (bot?.isTest == true) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '测试',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Colors.orange,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (bot != null && !bot!.canControl) ...[
                      const SizedBox(height: 6),
                      Text(
                        '未配置 Accounts 目录下的启停脚本（script_file）',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(running ? '运行中' : '已停止', style: statusStyle),
            ],
          ),
          const SizedBox(height: 12),

          _WebControlMetaRow(
            label: '赛季启动',
            value: seasonStart,
            labelColor: _labelColor,
            valueStyle: valueStyle,
          ),
          const SizedBox(height: 4),
          _WebControlMetaRow(
            label: '运行时长',
            value: seasonDuration,
            labelColor: _labelColor,
            valueStyle: valueStyle.copyWith(color: _numberColor),
          ),
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '策略启停',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Colors.cyanAccent.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _TradingBotControlStyleCircleButton(
                        isLoading: seasonBusy,
                        enabled: canCtl && !seasonBusy && onSeasonStart != null,
                        icon: Icons.play_arrow_rounded,
                        iconColor: Colors.green,
                        backgroundTint: Colors.green,
                        onTap: onSeasonStart,
                      ),
                      _TradingBotControlStyleCircleButton(
                        isLoading: seasonBusy,
                        enabled:
                            canCtl &&
                            !seasonBusy &&
                            hasOpenSeason &&
                            onSeasonStop != null,
                        icon: Icons.stop_rounded,
                        iconColor: Colors.red,
                        backgroundTint: Colors.red,
                        onTap: onSeasonStop,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          _WebControlMetaRow(
            label: '机器人启动',
            value: robotStart,
            labelColor: _labelColor,
            valueStyle: valueStyle,
          ),
          const SizedBox(height: 4),
          _WebControlMetaRow(
            label: '运行时长',
            value: robotDuration,
            labelColor: _labelColor,
            valueStyle: valueStyle.copyWith(color: _numberColor),
          ),
          const SizedBox(height: 10),
          Text(
            '进程控制',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 8),
          if (robotBusy)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (canCtl)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _WebRobotCircleIconButton(
                  isLoading: robotBusy,
                  enabled: !robotBusy && !running,
                  icon: Icons.play_arrow_rounded,
                  iconColor: Colors.green,
                  backgroundTint: Colors.green,
                  onTap: onStart,
                ),
                _WebRobotCircleIconButton(
                  isLoading: robotBusy,
                  enabled: !robotBusy && running,
                  icon: Icons.stop_rounded,
                  iconColor: Colors.red,
                  backgroundTint: Colors.red,
                  onTap: onStop,
                ),
                _WebRobotCircleIconButton(
                  isLoading: robotBusy,
                  enabled: !robotBusy,
                  icon: Icons.restart_alt_rounded,
                  iconColor: const Color(0xFF7EC850),
                  backgroundTint: const Color(0xFF7EC850),
                  onTap: onRestart,
                ),
              ],
            )
          else
            const SizedBox.shrink(),
          const Spacer(),
        ],
      ),
    );
  }
}

/// 与 [TradingBotControl._buildActionButton] 一致：56×56、`play`/`stop` 圆钮（策略启停 / 赛季）。
class _TradingBotControlStyleCircleButton extends StatelessWidget {
  const _TradingBotControlStyleCircleButton({
    required this.isLoading,
    required this.enabled,
    required this.icon,
    required this.iconColor,
    required this.backgroundTint,
    required this.onTap,
  });

  final bool isLoading;
  final bool enabled;
  final IconData icon;
  final Color iconColor;
  final Color backgroundTint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final canPress = enabled && !isLoading && onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canPress ? onTap : null,
        borderRadius: BorderRadius.circular(33),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: isLoading
                ? Colors.grey.withValues(alpha: 0.2)
                : (enabled
                      ? backgroundTint.withValues(alpha: 0.2)
                      : Colors.grey.withValues(alpha: 0.08)),
            shape: BoxShape.circle,
          ),
          child: isLoading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, color: enabled ? iconColor : Colors.grey, size: 36),
        ),
      ),
    );
  }
}

/// 机器人进程控制：保持 Web 当前较小圆钮（50×50、图标 32），与策略启停区分。
class _WebRobotCircleIconButton extends StatelessWidget {
  const _WebRobotCircleIconButton({
    required this.isLoading,
    required this.enabled,
    required this.icon,
    required this.iconColor,
    required this.backgroundTint,
    required this.onTap,
  });

  final bool isLoading;
  final bool enabled;
  final IconData icon;
  final Color iconColor;
  final Color backgroundTint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final canPress = enabled && !isLoading && onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canPress ? onTap : null,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: isLoading
                ? Colors.grey.withValues(alpha: 0.2)
                : (enabled
                      ? backgroundTint.withValues(alpha: 0.2)
                      : Colors.grey.withValues(alpha: 0.08)),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: isLoading
                ? Colors.grey.withValues(alpha: 0.35)
                : (enabled ? iconColor : Colors.grey),
            size: 32,
          ),
        ),
      ),
    );
  }
}

/// 与 [WebDashboardScreen] 概览卡一致：小标签 + 数值行。
class _WebControlMetaRow extends StatelessWidget {
  const _WebControlMetaRow({
    required this.label,
    required this.value,
    required this.labelColor,
    required this.valueStyle,
  });

  final String label;
  final String value;
  final Color labelColor;
  final TextStyle valueStyle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: labelColor),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: valueStyle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
