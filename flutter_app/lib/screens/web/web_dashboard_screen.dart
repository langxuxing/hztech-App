import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';
import 'web_account_profit_screen.dart';

/// Web：职责对齐 [AccountsList]，布局为多列玻璃卡网格。
/// 卡片样式借鉴 [TradingBotControl]，展示启动相关时间与启停操作，不含收益曲线与资金指标。
class WebDashboardScreen extends StatefulWidget {
  const WebDashboardScreen({super.key, this.sharedBots = const []});

  final List<UnifiedTradingBot> sharedBots;

  @override
  State<WebDashboardScreen> createState() => _WebDashboardScreenState();
}

class _WebDashboardScreenState extends State<WebDashboardScreen> {
  final _prefs = SecurePrefs();
  List<AccountProfit> _accounts = [];
  Map<String, List<BotSeason>> _seasonsByBot = {};
  bool _loading = true;
  String? _error;
  String? _loadingBotId;

  static String _fmtDateTimeShort(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$min';
  }

  static String _fmtDuration(Duration d) {
    if (d.isNegative) return '—';
    if (d.inSeconds < 60) return '${d.inSeconds} 秒';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟';
    if (d.inHours < 48) {
      return '${d.inHours} 小时 ${d.inMinutes.remainder(60)} 分';
    }
    return '${d.inDays} 天 ${d.inHours.remainder(24)} 小时';
  }

  /// 根据赛季列表与是否运行中，生成展示用文案。
  static ({String startLine, String durationLine}) _seasonLines(
    List<BotSeason> seasons,
    bool running,
  ) {
    if (seasons.isEmpty) {
      return (startLine: '暂无赛季记录', durationLine: '—');
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
          ? DateTime.tryParse(start)
          : null;
      final dur = parsed != null
          ? DateTime.now().difference(parsed)
          : Duration.zero;
      return (
        startLine: '本次启动 ${_fmtDateTimeShort(start)}',
        durationLine:
            parsed != null ? '已运行 ${_fmtDuration(dur)}' : '已运行 —',
      );
    }
    final last = seasons.first;
    final start = last.startedAt;
    final stop = last.stoppedAt;
    final ps = start != null && start.isNotEmpty ? DateTime.tryParse(start) : null;
    final pe = stop != null && stop.isNotEmpty ? DateTime.tryParse(stop) : null;
    String durationLine = '—';
    if (ps != null && pe != null) {
      durationLine = '上次运行 ${_fmtDuration(pe.difference(ps))}';
    } else if (ps != null && running) {
      durationLine = '已运行 ${_fmtDuration(DateTime.now().difference(ps))}';
    }
    return (
      startLine: '上次启动 ${_fmtDateTimeShort(start)}',
      durationLine: durationLine,
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
      try {
        final ids =
            accounts.map((a) => a.botId).where((id) => id.isNotEmpty).toList();
        if (ids.isNotEmpty) {
          final results = await Future.wait(
            ids.map((id) => api.getTradingbotSeasons(id, limit: 30)),
          );
          for (var i = 0; i < ids.length && i < results.length; i++) {
            seasonsMap[ids[i]] = results[i].seasons;
          }
        }
      } catch (_) {
        // 卡片仍显示，赛季失败时为空
      }
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _seasonsByBot = seasonsMap;
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
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
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
                            cross = 3;
                          } else if (w >= 800) {
                            cross = 2;
                          }
                          return SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: cross,
                                  mainAxisSpacing: 16,
                                  crossAxisSpacing: 16,
                                  childAspectRatio: cross >= 3 ? 1.35 : 1.2,
                                ),
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final a = _accounts[index];
                              final bot = _botFor(a);
                              final seasons = _seasonsByBot[a.botId] ?? const [];
                              final running = bot != null &&
                                  (bot.status == 'running' ||
                                      bot.isRunning == true);
                              final lines = _seasonLines(seasons, running);
                              return _AccountGlassCard(
                                account: a,
                                bot: bot,
                                startLine: lines.startLine,
                                durationLine: lines.durationLine,
                                loadingBotId: _loadingBotId,
                                onStart: bot != null && bot.canControl
                                    ? () => _doStart(bot)
                                    : null,
                                onStop: bot != null && bot.canControl
                                    ? () => _onTapStop(bot)
                                    : null,
                                onRestart: bot != null && bot.canControl
                                    ? () => _doRestart(bot)
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
    required this.startLine,
    required this.durationLine,
    required this.loadingBotId,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
    required this.onOpenDetail,
  });

  final AccountProfit account;
  final UnifiedTradingBot? bot;
  final String startLine;
  final String durationLine;
  final String? loadingBotId;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onRestart;
  final VoidCallback onOpenDetail;

  static const _cardLabelColor = AppFinanceStyle.labelColor;

  @override
  Widget build(BuildContext context) {
    final title =
        bot?.tradingbotName ??
        (account.exchangeAccount.isNotEmpty
            ? account.exchangeAccount
            : account.botId);
    final running = bot != null &&
        (bot!.status == 'running' || bot!.isRunning == true);
    final bid = bot?.tradingbotId ?? account.botId;
    final busy = loadingBotId == bid;

    return FinanceCard(
      padding: const EdgeInsets.all(20),
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
                            style:
                                (Theme.of(context).textTheme.titleLarge ??
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
                                      color: AppFinanceStyle.valueColor,
                                    ),
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
                    const SizedBox(height: 6),
                    Text(
                      running ? '运行中' : '已停止',
                      style: AppFinanceStyle.labelTextStyle(context).copyWith(
                        color: running
                            ? Colors.greenAccent
                            : AppFinanceStyle.labelColor,
                      ),
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
                    if (bot?.symbol != null && bot!.symbol!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '交易对 ${bot!.symbol}',
                        style: AppFinanceStyle.labelTextStyle(context),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            startLine,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _cardLabelColor,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            durationLine,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppFinanceStyle.valueColor,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const Spacer(),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (bot != null && bot!.canControl)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.start,
              children: [
                FilledButton.tonal(
                  onPressed: busy || running ? null : onStart,
                  child: const Text('启动'),
                ),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                  onPressed: busy || !running ? null : onStop,
                  child: const Text('停止'),
                ),
                FilledButton.tonal(
                  onPressed: busy ? null : onRestart,
                  child: const Text('重启'),
                ),
              ],
            )
          else
            const SizedBox.shrink(),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onOpenDetail,
              child: const Text('账户收益详情'),
            ),
          ),
        ],
      ),
    );
  }
}
