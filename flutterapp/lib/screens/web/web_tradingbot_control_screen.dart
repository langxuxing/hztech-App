import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';
import 'web_account_profile_screen.dart';

/// Web「策略启停」：与侧栏 [WebMainShell] 一致；多列玻璃卡网格，赛季 + 机器人会话时长 + 启停/重启。
/// 账户级资金曲线与汇总见侧栏「账户总览」[WebDashboardScreen]。
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
  /// 与 `/api/tradingbots` 同步，用于角标「运行中/已停止」；避免仅用 shell 下放的 sharedBots 导致启停后状态不刷新。
  List<UnifiedTradingBot> _botsSnapshot = [];
  bool _loading = true;
  String? _error;
  String? _loadingBotId;
  String? _seasonLoadingBotId;
  bool _bulkBusy = false;

  static void _logControl(String icon, String action, UnifiedTradingBot bot, {
    required bool success,
    String? detail,
  }) {
    final tail = detail != null && detail.isNotEmpty ? ' $detail' : '';
    debugPrint(
      '🛡 $icon [$action] bot=${bot.tradingbotId} '
      '(${bot.tradingbotName ?? bot.tradingbotId}) success=$success$tail',
    );
  }

  void _patchBotRuntimeStatus(String botId, String apiStatus) {
    final running = apiStatus == 'running';
    final idx = _botsSnapshot.indexWhere((b) => b.tradingbotId == botId);
    if (idx < 0) return;
    final b = _botsSnapshot[idx];
    _botsSnapshot[idx] = UnifiedTradingBot(
      tradingbotId: b.tradingbotId,
      tradingbotName: b.tradingbotName,
      exchangeAccount: b.exchangeAccount,
      symbol: b.symbol,
      strategyName: b.strategyName,
      status: apiStatus,
      isRunning: running,
      canControl: b.canControl,
      isTest: b.isTest,
    );
  }

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

  /// 未满 24 小时：「X 分钟」或「X 小时」/「X 小时 Y 分钟」（不显示「0 天」）；
  /// 满 24 小时及以上：仅「X 天 Y 小时」（按整小时计，零头分钟不计入显示）。
  static String _fmtDaysHours(Duration d) {
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
      List<UnifiedTradingBot> freshBots = [];
      try {
        final botsResp = await api.getTradingBots();
        freshBots = botsResp.botList;
      } catch (_) {}
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
        if (freshBots.isNotEmpty) {
          _botsSnapshot = freshBots;
        }
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
    for (final b in _botsSnapshot) {
      if (b.tradingbotId == a.botId) return b;
    }
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
      final st = resp.status;
      setState(() {
        _loadingBotId = null;
        if (resp.success && st != null && st.isNotEmpty) {
          _patchBotRuntimeStatus(bot.tradingbotId, st);
        }
      });
      _logControl('▶️', '策略启动', bot, success: resp.success, detail: resp.message);
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
      final st = resp.status;
      setState(() {
        _loadingBotId = null;
        if (resp.success && st != null && st.isNotEmpty) {
          _patchBotRuntimeStatus(bot.tradingbotId, st);
        }
      });
      _logControl('⏹️', '策略停止', bot, success: resp.success, detail: resp.message);
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
      final st = resp.status;
      setState(() {
        _loadingBotId = null;
        if (resp.success && st != null && st.isNotEmpty) {
          _patchBotRuntimeStatus(bot.tradingbotId, st);
        }
      });
      _logControl('🔄', '策略重启', bot, success: resp.success, detail: resp.message);
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

  void _onTapStrategyStart(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    if (running) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.play_arrow_rounded, color: AppFinanceStyle.textProfit),
            const SizedBox(width: 8),
            const Expanded(child: Text('确认启动策略')),
          ],
        ),
        content: const Text(
          '确定要启动该账户的交易策略进程吗？启动后将按脚本连接交易所并运行策略逻辑。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppFinanceStyle.textProfit,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _doStart(bot);
            },
            child: const Text('确定启动'),
          ),
        ],
      ),
    );
  }

  void _onTapStrategyRestart(UnifiedTradingBot bot) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.refresh_rounded, color: const Color(0xFFB9B5D9)),
            const SizedBox(width: 8),
            const Expanded(child: Text('确认重启策略')),
          ],
        ),
        content: const Text(
          '重启会先停止再启动策略进程，期间持仓与订单状态取决于脚本实现。确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF4A4868),
              foregroundColor: const Color(0xFFE8E6FF),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _doRestart(bot);
            },
            child: const Text('确定重启'),
          ),
        ],
      ),
    );
  }

  void _onTapStop(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    if (!running) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.stop_rounded, color: AppFinanceStyle.textLoss),
            const SizedBox(width: 8),
            const Expanded(child: Text('确认停止策略')),
          ],
        ),
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

  Future<void> _doSeasonStart(UnifiedTradingBot bot) async {
    setState(() => _seasonLoadingBotId = bot.tradingbotId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.seasonStartBot(bot.tradingbotId);
      if (!mounted) return;
      final st = resp.status;
      setState(() {
        _seasonLoadingBotId = null;
        if (resp.success && st != null && st.isNotEmpty) {
          _patchBotRuntimeStatus(bot.tradingbotId, st);
        }
      });
      _logControl('📈', '赛季启动', bot, success: resp.success, detail: resp.message);
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
      final st = resp.status;
      setState(() {
        _seasonLoadingBotId = null;
        if (resp.success && st != null && st.isNotEmpty) {
          _patchBotRuntimeStatus(bot.tradingbotId, st);
        }
      });
      _logControl('📉', '赛季结束', bot, success: resp.success, detail: resp.message);
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

  void _onTapSeasonStart(UnifiedTradingBot bot) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.trending_up_rounded, color: AppFinanceStyle.textProfit),
            const SizedBox(width: 8),
            const Expanded(child: Text('确认开启赛季')),
          ],
        ),
        content: const Text(
          '将新开一季并可能按需拉起策略进程；请确认账户与风控已就绪。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppFinanceStyle.textProfit,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _doSeasonStart(bot);
            },
            child: const Text('确定开启'),
          ),
        ],
      ),
    );
  }

  void _onTapSeasonStop(UnifiedTradingBot bot) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.flag_rounded, color: Colors.deepOrange),
            const SizedBox(width: 8),
            const Expanded(child: Text('确认结束赛季')),
          ],
        ),
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
    return s.contains('error') || s == 'failed' || s.contains('exception');
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
    return (
      total: _accounts.length,
      running: running,
      stopped: stopped,
      error: err,
    );
  }

  List<UnifiedTradingBot> _controllableBots() => _accounts
      .map(_botFor)
      .whereType<UnifiedTradingBot>()
      .where((b) => b.canControl)
      .toList();

  Future<void> _bulkStartAll() async {
    if (_bulkBusy) return;
    final targets = _controllableBots()
        .where((b) => !_isBotRunning(b))
        .toList();
    if (targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('没有处于停止状态且可管控的账户')));
      }
      return;
    }
    final go =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Row(
              children: [
                Icon(
                  Icons.play_arrow_rounded,
                  color: AppFinanceStyle.textProfit,
                ),
                const SizedBox(width: 8),
                const Expanded(child: Text('确认全部启动')),
              ],
            ),
            content: Text('将依次启动 ${targets.length} 个机器人进程，是否继续？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppFinanceStyle.textProfit,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定启动'),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前没有运行中的可管控账户')));
      }
      return;
    }
    final go =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.stop_rounded, color: AppFinanceStyle.textLoss),
                const SizedBox(width: 8),
                const Expanded(child: Text('确认全部停止')),
              ],
            ),
            content: Text('将依次停止 ${targets.length} 个机器人进程，是否继续？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppFinanceStyle.textLoss,
                ),
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
    _botsSnapshot = List<UnifiedTradingBot>.from(widget.sharedBots);
    _load();
  }

  void _openAccount(AccountProfit a) {
    final id = a.botId.isNotEmpty ? a.botId : null;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => WebAccountProfitScreen(
          sharedBots:
              _botsSnapshot.isNotEmpty ? _botsSnapshot : widget.sharedBots,
          initialBotId: id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = _aggregateStats();

    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: Stack(
          fit: StackFit.expand,
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
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                          sliver: SliverToBoxAdapter(
                            child: _GlobalBotStatsBar(
                              total: stats.total,
                              running: stats.running,
                              stopped: stats.stopped,
                              errorCount: stats.error,
                              bulkBusy: _bulkBusy,
                              onBulkStart: _bulkStartAll,
                              onBulkStop: _bulkStopAll,
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
                                  style: AppFinanceStyle.labelTextStyle(
                                    context,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                            sliver: Builder(
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
                                        childAspectRatio: cross >= 3
                                            ? 0.91
                                            : 0.78,
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
                                    return Align(
                                      alignment: Alignment.topCenter,
                                      child: _AccountGlassCard(
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
                                            ? () => _onTapStrategyStart(bot)
                                            : null,
                                        onStop: bot != null && bot.canControl
                                            ? () => _onTapStop(bot)
                                            : null,
                                        onRestart: bot != null && bot.canControl
                                            ? () => _onTapStrategyRestart(bot)
                                            : null,
                                        onSeasonStart:
                                            bot != null && bot.canControl
                                            ? () => _onTapSeasonStart(bot)
                                            : null,
                                        onSeasonStop:
                                            bot != null && bot.canControl
                                            ? () => _onTapSeasonStop(bot)
                                            : null,
                                        onOpenDetail: () => _openAccount(a),
                                      ),
                                    );
                                  }, childCount: _accounts.length),
                                );
                              },
                            ),
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

/// 顶部全局统计与一键启停；统计区与 [WebDashboardScreen] 账户总览条一致（标题 + FinanceCard + 汇总列）。
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

  @override
  Widget build(BuildContext context) {
    TextStyle v() => AppFinanceStyle.valueTextStyle(
      context,
      fontSize: AppFinanceStyle.webSummaryValueFontSize,
    );
    final stoppedStyle = v().copyWith(color: AppFinanceStyle.labelColor);
    final errorStyle = v().copyWith(
      color: errorCount > 0
          ? AppFinanceStyle.textLoss
          : AppFinanceStyle.labelColor,
    );

    final bulkActions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.tonalIcon(
          onPressed: bulkBusy ? null : onBulkStart,
          style: FilledButton.styleFrom(
            foregroundColor: AppFinanceStyle.textProfit,
            backgroundColor: AppFinanceStyle.textProfit.withValues(alpha: 0.14),
          ),
          icon: Icon(
            Icons.play_circle_outline,
            size: 20,
            color: bulkBusy ? null : AppFinanceStyle.textProfit,
          ),
          label: const Text('全部启动'),
        ),
        const SizedBox(width: 10),
        FilledButton.tonalIcon(
          onPressed: bulkBusy ? null : onBulkStop,
          style: FilledButton.styleFrom(
            foregroundColor: AppFinanceStyle.textLoss,
            backgroundColor: AppFinanceStyle.textLoss.withValues(alpha: 0.12),
          ),
          icon: Icon(
            Icons.stop_circle_outlined,
            size: 20,
            color: bulkBusy ? null : AppFinanceStyle.textLoss,
          ),
          label: const Text('全部停止'),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppFinanceStyle.webSummaryTitleSpacing),
        FinanceCard(
          padding: AppFinanceStyle.webSummaryStripPadding,
          child: LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < 520;
              final cells = [
                _BotControlSummaryCell(
                  label: '总计',
                  value: '$total',
                  valueStyle: v(),
                  trailingLabel: !narrow,
                ),
                _BotControlSummaryCell(
                  label: '运行中',
                  value: '$running',
                  valueStyle: v().copyWith(
                    color: AppFinanceStyle.profitGreenEnd,
                  ),
                  trailingLabel: !narrow,
                ),
                _BotControlSummaryCell(
                  label: '已停止',
                  value: '$stopped',
                  valueStyle: stoppedStyle,
                  trailingLabel: !narrow,
                ),
                _BotControlSummaryCell(
                  label: '异常',
                  value: '$errorCount',
                  valueStyle: errorStyle,
                  trailingLabel: !narrow,
                ),
              ];
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < cells.length; i++) ...[
                      if (i > 0)
                        const SizedBox(
                          height: AppFinanceStyle.webSummaryNarrowGap,
                        ),
                      cells[i],
                    ],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < cells.length; i++) ...[
                    if (i > 0)
                      const SizedBox(width: AppFinanceStyle.webSummaryWideGap),
                    Expanded(child: cells[i]),
                  ],
                ],
              );
            },
          ),
        ),
        const SizedBox(height: AppFinanceStyle.webSummaryCardToBulkActionsGap),
        LayoutBuilder(
          builder: (context, c) {
            final narrow = c.maxWidth < 520;
            if (narrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [bulkActions],
              );
            }
            return Align(alignment: Alignment.centerRight, child: bulkActions);
          },
        ),
      ],
    );
  }
}

/// 与 dashboard `_SummaryCell` 相同的标签+数值排版（基线对齐）。
class _BotControlSummaryCell extends StatelessWidget {
  const _BotControlSummaryCell({
    required this.label,
    required this.value,
    required this.valueStyle,
    required this.trailingLabel,
  });

  final String label;
  final String value;
  final TextStyle valueStyle;
  final bool trailingLabel;

  @override
  Widget build(BuildContext context) {
    final baseLabel = AppFinanceStyle.labelTextStyle(context);
    final labelStyle = baseLabel.copyWith(
      fontSize: (baseLabel.fontSize ?? 14) - 2,
    );
    final ta = trailingLabel ? TextAlign.end : TextAlign.start;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label, style: labelStyle, textAlign: ta),
        const SizedBox(width: 6),
        Text(
          value,
          style: valueStyle,
          textAlign: ta,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
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

  /// 顶部「运行中」角标与脉冲点（略亮以保证可读）
  static const _greenRun = AppFinanceStyle.textProfit;

  /// 赛季/策略控制区外层 box：与右上角「全部启动/全部停止」同色同透明度（alpha 0.14 / 0.12），胶囊圆角。
  static BoxDecoration get _seasonControlBoxDecoration => BoxDecoration(
    borderRadius: BorderRadius.circular(999),
    border: Border.all(
      color: AppFinanceStyle.textProfit.withValues(alpha: 0.22),
      width: 1,
    ),
    color: AppFinanceStyle.textProfit.withValues(alpha: 0.14),
  );

  static BoxDecoration get _strategyControlBoxDecoration => BoxDecoration(
    borderRadius: BorderRadius.circular(999),
    border: Border.all(
      color: AppFinanceStyle.textLoss.withValues(alpha: 0.22),
      width: 1,
    ),
    color: AppFinanceStyle.textLoss.withValues(alpha: 0.12),
  );

  /// 控制区相对原先尺寸：宽约 80%；内边距较上一版收紧约 25% 以降低卡片高度。
  static const double _controlBoxScale = 0.75;
  static const EdgeInsets _controlBoxPadding = EdgeInsets.fromLTRB(8, 5, 8, 8);

  /// 赛季/策略控制圆钮：与概览区「全部启动/停止」同款——深色实底 + 亮色图标
  static const _ctrlStartFill = Color(0xFF16352A);
  static const _ctrlStartIcon = AppFinanceStyle.textProfit;
  static const _ctrlStopFill = Color(0xFF3A1F22);
  static const _ctrlStopIcon = AppFinanceStyle.textLoss;
  static const _ctrlRestartFill = Color(0xFF2C2A35);
  static const _ctrlRestartIcon = Color(0xFFB9B5D9);
  static const _durationMuted = Color(0xFF8FA9A5);

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
    return s.contains('error') || s == 'failed' || s.contains('exception');
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

  /// 占位（—、空、时长 00:00:00）在界面上显示为空，标题「启动」仍保留。
  static String _runtimeFieldDisplay(String s, {required bool isDuration}) {
    if (s.isEmpty || s == '—') return '';
    if (isDuration && s == '00:00:00') return '';
    return s;
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
          fontSize:
              (Theme.of(context).textTheme.titleMedium?.fontSize ?? 20) + 1,
          color: AppFinanceStyle.valueColor,
          letterSpacing: 0.2,
        );

    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: const Color.fromARGB(255, 206, 206, 209).withValues(alpha: 0.62),
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
      fontSize: 16,
    );

    final kickoffLabelStyle = labelStyle?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: _labelMuted.withValues(alpha: 0.48),
      letterSpacing: 0.2,
    );

    final metaStyle = AppFinanceStyle.valueTextStyle(context, fontSize: 13)
        .copyWith(
          color: _labelMuted.withValues(alpha: 0.88),
          fontWeight: FontWeight.w600,
        );

    final durationStyle = AppFinanceStyle.valueTextStyle(context, fontSize: 22)
        .copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 16,
          color: _durationMuted,
          letterSpacing: 0.5,
          fontFeatures: const [FontFeature.tabularFigures()],
        );

    final glowT = _running ? _pulse.value : 0.0;
    final seasonStartShown = _runtimeFieldDisplay(
      widget.seasonStart,
      isDuration: false,
    );
    final seasonDurationShown = _runtimeFieldDisplay(
      widget.seasonDuration,
      isDuration: true,
    );
    final robotStartShown = _runtimeFieldDisplay(
      widget.robotStart,
      isDuration: false,
    );
    final robotDurationShown = _runtimeFieldDisplay(
      widget.robotDuration,
      isDuration: true,
    );

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        return FinanceCard(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
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
                                    color: const Color(
                                      0xFFFFB74D,
                                    ).withValues(alpha: 0.55),
                                  ),
                                  color: const Color(
                                    0xFFFFB74D,
                                  ).withValues(alpha: 0.12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(
                                        0xFFFFB74D,
                                      ).withValues(alpha: 0.22),
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
                            '未配置 accounts 目录下的启停脚本（script_file）',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
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
              const SizedBox(height: 13),
              Text('赛季控制', style: labelStyle), //赛季控制
              const SizedBox(height: 9),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text('启动时间 ', style: kickoffLabelStyle),
                        Expanded(
                          child: Text(
                            seasonStartShown,
                            style: metaStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(seasonDurationShown, style: durationStyle),
                ],
              ),
              const SizedBox(height: 8),

              Align(
                alignment: Alignment.center,
                child: FractionallySizedBox(
                  widthFactor: _controlBoxScale,
                  child: Container(
                    decoration: _seasonControlBoxDecoration,
                    child: Padding(
                      padding: _controlBoxPadding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: 6 * _controlBoxScale),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _CyberCircleIconButton(
                                size: 38 * _controlBoxScale,
                                iconSize: 20 * _controlBoxScale,
                                isLoading: seasonBusy,
                                enabled:
                                    canCtl &&
                                    !seasonBusy &&
                                    widget.onSeasonStart != null,
                                icon: Icons.play_arrow_rounded,
                                fillColor: _ctrlStartFill,
                                iconColor: _ctrlStartIcon,
                                onTap: widget.onSeasonStart,
                              ),
                              _CyberCircleIconButton(
                                size: 38 * _controlBoxScale,
                                iconSize: 20 * _controlBoxScale,
                                isLoading: seasonBusy,
                                enabled:
                                    canCtl &&
                                    !seasonBusy &&
                                    widget.hasOpenSeason &&
                                    widget.onSeasonStop != null,
                                icon: Icons.stop_rounded,
                                fillColor: _ctrlStopFill,
                                iconColor: _ctrlStopIcon,
                                onTap: widget.onSeasonStop,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),
              Divider(
                height: 1,
                thickness: 1,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              const SizedBox(height: 13),
              Text('策略控制', style: labelStyle),
              const SizedBox(height: 9),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text('启动时间 ', style: kickoffLabelStyle),
                        Expanded(
                          child: Text(
                            robotStartShown,
                            style: metaStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(robotDurationShown, style: durationStyle),
                ],
              ),

              const SizedBox(height: 8),
              Align(
                alignment: Alignment.center,
                child: FractionallySizedBox(
                  widthFactor: _controlBoxScale,
                  child: Container(
                    decoration: _strategyControlBoxDecoration,
                    child: Padding(
                      padding: _controlBoxPadding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: 6 * _controlBoxScale),
                          if (robotBusy) ...[
                            SizedBox(height: 5 * _controlBoxScale),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: const LinearProgressIndicator(
                                minHeight: 3,
                              ),
                            ),
                          ] else if (_running) ...[
                            SizedBox(height: 5 * _controlBoxScale),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 3,
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.06,
                                ),
                                color: AppFinanceStyle.valueColor.withValues(
                                  alpha: 0.45,
                                ),
                              ),
                            ),
                          ],
                          SizedBox(height: 8 * _controlBoxScale),
                          if (canCtl)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _CyberCircleIconButton(
                                  size: 36 * _controlBoxScale,
                                  iconSize: 18 * _controlBoxScale,
                                  isLoading: robotBusy,
                                  enabled: !robotBusy && !_running,
                                  icon: Icons.play_arrow_rounded,
                                  fillColor: _ctrlStartFill,
                                  iconColor: _ctrlStartIcon,
                                  onTap: widget.onStart,
                                ),
                                _CyberCircleIconButton(
                                  size: 36 * _controlBoxScale,
                                  iconSize: 18 * _controlBoxScale,
                                  isLoading: robotBusy,
                                  enabled: !robotBusy && _running,
                                  icon: Icons.stop_rounded,
                                  fillColor: _ctrlStopFill,
                                  iconColor: _ctrlStopIcon,
                                  onTap: widget.onStop,
                                ),
                                _CyberCircleIconButton(
                                  size: 36 * _controlBoxScale,
                                  iconSize: 18 * _controlBoxScale,
                                  isLoading: robotBusy,
                                  enabled: !robotBusy,
                                  icon: Icons.refresh_rounded,
                                  fillColor: _ctrlRestartFill,
                                  iconColor: _ctrlRestartIcon,
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
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 深色实底圆钮 + 亮色图标（与概览区 FilledButton.tonal 同款对比关系）。
class _CyberCircleIconButton extends StatefulWidget {
  const _CyberCircleIconButton({
    required this.size,
    required this.iconSize,
    required this.isLoading,
    required this.enabled,
    required this.icon,
    required this.fillColor,
    required this.iconColor,
    required this.onTap,
  });

  final double size;
  final double iconSize;
  final bool isLoading;
  final bool enabled;
  final IconData icon;

  /// 圆形填充色（不透明深色调）。
  final Color fillColor;

  /// 图标、描边与加载环高亮色。
  final Color iconColor;
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
    final fg = widget.iconColor;
    final base = widget.fillColor;

    Color bgFill;
    if (!canPress) {
      bgFill = Color.alphaBlend(
        base.withValues(alpha: 0.42),
        const Color(0xFF121212),
      );
    } else if (_pressed) {
      bgFill = Color.lerp(base, fg, 0.22)!;
    } else if (_hover) {
      bgFill = Color.lerp(base, fg, 0.12)!;
    } else {
      bgFill = base;
    }

    final borderA = canPress
        ? (_pressed ? 0.62 : (_hover ? 0.48 : 0.32))
        : 0.14;
    final glowA = canPress ? (_pressed ? 0.35 : (_hover ? 0.22 : 0.12)) : 0.0;

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
            border: Border.all(
              color: fg.withValues(alpha: borderA),
              width: canPress ? 1.5 : 1,
            ),
            color: bgFill,
            boxShadow: glowA > 0.01
                ? [
                    BoxShadow(
                      color: fg.withValues(alpha: glowA),
                      blurRadius: _pressed ? 10 : 8,
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
                    color: fg.withValues(alpha: 0.95),
                  ),
                )
              : Icon(
                  widget.icon,
                  size: widget.iconSize,
                  color: canPress ? fg : fg.withValues(alpha: 0.38),
                ),
        ),
      ),
    );
  }
}
