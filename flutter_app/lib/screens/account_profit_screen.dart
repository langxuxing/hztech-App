import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../widgets/month_end_profit_panel.dart';
import '../widgets/profit_percent_line_chart.dart';
import '../widgets/water_background.dart';

class AccountProfitScreen extends StatefulWidget {
  const AccountProfitScreen({
    super.key,
    this.sharedBots = const [],
    this.initialBotId,
    this.periodicRefreshActive = true,
    this.webLayout = false,
    this.embedInShell = false,
  });

  /// 由 MainScreen 下发的交易账户列表，与账户管理同源，保证下拉框有数据
  final List<UnifiedTradingBot> sharedBots;

  /// 进入页面时默认选中的交易账户（例如从账户管理列表点入）
  final String? initialBotId;

  /// 为 false 时不启动定时刷新（例如嵌在 MainScreen 非当前 Tab 时避免后台请求）
  final bool periodicRefreshActive;

  /// Web 宽屏分栏布局（由 [WebAccountProfitScreen] 传入）
  final bool webLayout;

  /// 嵌入 Web 主导航壳时不显示本页 [AppBar]。
  final bool embedInShell;

  @override
  State<AccountProfitScreen> createState() => _AccountProfitScreenState();
}

class _AccountProfitScreenState extends State<AccountProfitScreen> {
  final _prefs = SecurePrefs();
  List<AccountProfit> _accounts = [];
  List<UnifiedTradingBot> _bots = [];
  String? _selectedBotId;
  List<BotProfitSnapshot> _snapshots = [];
  List<OkxPosition> _positions = [];
  List<BotSeason> _seasons = [];
  bool _loading = true;
  String? _error;
  String? _positionsLoadError;
  Map<String, dynamic>? _positionsOkxDebug;
  Timer? _autoRefreshTimer;
  static const String _defaultBotId = 'simpleserver';

  /// 保持当前选中账户，拉取最新收益、曲线、持仓与赛季（用于定时刷新与下拉切换后的全量刷新）
  Future<void> _refreshLatestData() async {
    if (!mounted || _loading) return;
    final list = _bots.isNotEmpty ? _bots : widget.sharedBots;
    final botId = _selectedBotId ??
        (list.isNotEmpty ? list.first.tradingbotId : null) ??
        _defaultBotId;
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final phase2 = await Future.wait([
        api.getAccountProfit(),
        api.getBotProfitHistory(botId, limit: 500),
      ]);
      if (!mounted) return;
      final profitResp = phase2[0] as AccountProfitResponse;
      final historyResp = phase2[1] as BotProfitHistoryResponse;
      setState(() {
        _accounts = profitResp.accounts ?? [];
        _snapshots = historyResp.snapshots;
      });
      final phase3 = await Future.wait([
        api.getTradingbotPositions(botId),
        api.getTradingbotSeasons(botId, limit: 50),
      ]);
      if (!mounted) return;
      final positionsResp = phase3[0] as OkxPositionsResponse;
      final seasonsResp = phase3[1] as TradingbotSeasonsResponse;
      setState(() {
        _positions = positionsResp.positions;
        _positionsLoadError = positionsResp.positionsError;
        _positionsOkxDebug = positionsResp.okxDebug;
        _seasons = seasonsResp.seasons;
      });
    } catch (_) {
      // 后台轮询失败不打扰主流程
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 并行读配置，减少首包延迟
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);

      // 优先 MainScreen 下发的列表；否则本页拉取（与账户管理同源）
      List<UnifiedTradingBot> bots = List.from(widget.sharedBots);
      if (bots.isEmpty) {
        final botsResp = await api.getTradingBots();
        bots = botsResp.botList;
      }
      final initial = widget.initialBotId?.trim();
      if (initial != null && initial.isNotEmpty) {
        final has = bots.any((b) => b.tradingbotId == initial);
        if (!has) {
          bots = [
            UnifiedTradingBot(
              tradingbotId: initial,
              status: '',
              canControl: false,
              isTest: false,
            ),
            ...bots,
          ];
        }
      }
      final botId = (initial != null && initial.isNotEmpty)
          ? initial
          : (bots.isNotEmpty ? bots.first.tradingbotId : _defaultBotId);

      if (!mounted) return;
      // 阶段一：一有账户列表就结束全屏 loading，下拉框可立即显示
      setState(() {
        _bots = bots;
        _selectedBotId = botId;
        _loading = false;
      });

      // 阶段二：账户收益 + 历史（不经过 OKX 直连，通常较快）
      try {
        final phase2 = await Future.wait([
          api.getAccountProfit(),
          api.getBotProfitHistory(botId, limit: 500),
        ]);
        if (!mounted) return;
        final profitResp = phase2[0] as AccountProfitResponse;
        final historyResp = phase2[1] as BotProfitHistoryResponse;
        setState(() {
          _accounts = profitResp.accounts ?? [];
          _snapshots = historyResp.snapshots;
        });
      } catch (e) {
        if (mounted) {
          setState(() => _error = '收益/历史加载失败: $e');
        }
      }

      // 阶段三：持仓 + 赛季（后端可能调 OKX，1010/慢响应不再阻塞上面两阶段）
      try {
        final phase3 = await Future.wait([
          api.getTradingbotPositions(botId),
          api.getTradingbotSeasons(botId, limit: 50),
        ]);
        if (!mounted) return;
        final positionsResp = phase3[0] as OkxPositionsResponse;
        final seasonsResp = phase3[1] as TradingbotSeasonsResponse;
        setState(() {
          _positions = positionsResp.positions;
          _positionsLoadError = positionsResp.positionsError;
          _positionsOkxDebug = positionsResp.okxDebug;
          _seasons = seasonsResp.seasons;
        });
      } catch (e) {
        if (mounted) {
          setState(() {
            _positionsLoadError = '持仓/赛季加载异常: $e';
            _positionsOkxDebug = null;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadForBot(String botId) async {
    setState(() => _selectedBotId = botId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final results = await Future.wait([
        api.getAccountProfit(),
        api.getBotProfitHistory(botId, limit: 500),
        api.getTradingbotSeasons(botId, limit: 50),
        api.getTradingbotPositions(botId),
      ]);
      if (!mounted) return;
      final profitResp = results[0] as AccountProfitResponse;
      final historyResp = results[1] as BotProfitHistoryResponse;
      final seasonsResp = results[2] as TradingbotSeasonsResponse;
      final positionsResp = results[3] as OkxPositionsResponse;
      setState(() {
        _accounts = profitResp.accounts ?? [];
        _snapshots = historyResp.snapshots;
        _seasons = seasonsResp.seasons;
        _positions = positionsResp.positions;
        _positionsLoadError = positionsResp.positionsError;
        _positionsOkxDebug = positionsResp.okxDebug;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '切换账户后加载失败: $e');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // 若父级已下发列表则先展示，再异步拉取收益等
    if (widget.sharedBots.isNotEmpty) {
      _bots = List.from(widget.sharedBots);
      _selectedBotId = _bots.first.tradingbotId;
    }
    _load();
    _syncAutoRefreshTimer();
  }

  void _syncAutoRefreshTimer() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    if (!widget.periodicRefreshActive) return;
    _autoRefreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshLatestData(),
    );
  }

  @override
  void didUpdateWidget(covariant AccountProfitScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.periodicRefreshActive != widget.periodicRefreshActive) {
      _syncAutoRefreshTimer();
    }
    // MainScreen 异步加载完 bots 后下发，同步到本页以显示下拉框
    if (widget.sharedBots.isNotEmpty &&
        widget.sharedBots.length != _bots.length) {
      _bots = List.from(widget.sharedBots);
      if (_selectedBotId == null ||
          !_bots.any((b) => b.tradingbotId == _selectedBotId)) {
        _selectedBotId = _bots.first.tradingbotId;
      }
      setState(() {});
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  String _fmt(double v) => v.toStringAsFixed(2);
  String _fmtPct(double v) => '${v.toStringAsFixed(2)}%';

  String _formatOkxDebug(Map<String, dynamic> m) {
    final b = StringBuffer();
    final ip = m['server_egress_ip'];
    if (ip != null) b.writeln('服务器出口 IP: $ip');
    final cf = m['config_file'];
    if (cf != null) b.writeln('OKX 配置: $cf');
    final masked = m['apikey_masked'];
    if (masked != null) b.writeln('API Key: $masked');
    if (m['sandbox'] == true) b.writeln('沙盒: 是');
    final note = m['note'];
    if (note != null) b.writeln(note);
    return b.toString().trim();
  }

  Widget _buildOkxDebugHint() {
    final d = _positionsOkxDebug;
    if (d == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SelectableText(
        _formatOkxDebug(d),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 11,
          height: 1.35,
          color: AppFinanceStyle.labelColor.withValues(alpha: 0.88),
        ),
      ),
    );
  }

  /// 将赛季时间格式化为 月-日 时:分
  String _formatSeasonTime(String? value) {
    if (value == null || value.length < 16) return '-';
    try {
      // 支持 "2025-03-01T12:00:00" 或 "2025-03-01 12:00:00"
      final s = value
          .substring(0, value.length >= 19 ? 19 : value.length)
          .replaceAll('T', ' ');
      if (s.length < 16) return '-';
      final parts = s.split(' ');
      final dateParts = parts[0].split('-');
      final timePart = parts.length > 1 ? parts[1].substring(0, 5) : '00:00';
      if (dateParts.length < 3) return '-';
      return '${dateParts[1]}-${dateParts[2]} $timePart';
    } catch (_) {
      return '-';
    }
  }

  /// 优先用本页 _bots，为空则用 MainScreen 下发的 sharedBots，保证有数据即显示下拉框
  List<UnifiedTradingBot> get _effectiveBots =>
      _bots.isNotEmpty ? _bots : widget.sharedBots;

  int get _selectedBotIndex {
    final list = _effectiveBots;
    if (_selectedBotId == null || list.isEmpty) return 0;
    final i = list.indexWhere((b) => b.tradingbotId == _selectedBotId);
    return i >= 0 ? i : 0;
  }

  AccountProfit? get _selectedAccount {
    if (_accounts.isEmpty) return null;
    if (_selectedBotId != null && _selectedBotId!.isNotEmpty) {
      try {
        return _accounts.firstWhere((a) => a.botId == _selectedBotId);
      } on StateError {
        // fallback to index
      }
    }
    final i = _selectedBotIndex;
    return i < _accounts.length ? _accounts[i] : _accounts.first;
  }

  Widget _buildBotSelector() {
    final list = _effectiveBots;
    if (list.isEmpty) return const SizedBox.shrink();
    // 无论 1 个或多个交易账户都使用 DropdownButton，交互一致
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.of(context).size.width * 0.45).clamp(160.0, 280.0),
          minHeight: kMinInteractiveDimension,
        ),
        child: _glassCard(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: DropdownButton<String>(
              value: _selectedBotId ?? list.first.tradingbotId,
              isExpanded: true,
              dropdownColor: AppFinanceStyle.cardBackground.withValues(
                alpha: 0.98,
              ),
              style: const TextStyle(color: AppFinanceStyle.valueColor),
              items: list
                  .map(
                    (b) => DropdownMenuItem<String>(
                      value: b.tradingbotId,
                      child: Text(
                        b.tradingbotName ?? b.tradingbotId,
                        style: const TextStyle(
                          color: AppFinanceStyle.valueColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) _loadForBot(v);
              },
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  Widget _glassCard(Widget child, {EdgeInsetsGeometry? padding}) {
    return FinanceCard(
      padding: padding ?? const EdgeInsets.all(20),
      child: child,
    );
  }

  List<Widget> _buildMainColumnChildren() {
    return [
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            _error!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 13,
            ),
          ),
        ),
      if (_effectiveBots.isNotEmpty) ...[
        _buildBotSelector(),
        const SizedBox(height: 24),
      ],
      if (_accounts.isEmpty && _error == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              '暂无账户数据，请确认后端 Accounts 已配置交易账户',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ),
      _buildAccountOverview(),
      const SizedBox(height: 32),
      _buildProfitChart(),
      const SizedBox(height: 32),
      _buildMonthEndSection(),
      const SizedBox(height: 32),
      _buildPositions(),
      const SizedBox(height: 32),
      _buildSeasons(),
    ];
  }

  Widget _buildBodyScrollable() {
    final wide =
        widget.webLayout && MediaQuery.sizeOf(context).width >= 960;
    if (wide) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  if (_effectiveBots.isNotEmpty) ...[
                    _buildBotSelector(),
                    const SizedBox(height: 24),
                  ],
                  if (_accounts.isEmpty && _error == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          '暂无账户数据，请确认后端 Accounts 已配置交易账户',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
                  _buildAccountOverview(),
                  const SizedBox(height: 32),
                  _buildProfitChart(),
                  const SizedBox(height: 32),
                  _buildMonthEndSection(),
                ],
              ),
            ),
            const SizedBox(width: 28),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPositions(),
                  const SizedBox(height: 32),
                  _buildSeasons(),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
      children: _buildMainColumnChildren(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: widget.embedInShell
          ? null
          : AppBar(
              leading: widget.webLayout && canPop
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).pop(),
                    )
                  : null,
              automaticallyImplyLeading: !(widget.webLayout && canPop),
              title: Text(
                widget.webLayout ? '账户详情' : '账户收益',
                style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  color: AppFinanceStyle.valueColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              backgroundColor: AppFinanceStyle.backgroundDark,
              foregroundColor: AppFinanceStyle.valueColor,
              surfaceTintColor: Colors.transparent,
            ),
      body: WaterBackground(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading && _accounts.isEmpty && _effectiveBots.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _accounts.isEmpty && _effectiveBots.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : _buildBodyScrollable(),
        ),
      ),
    );
  }

  Widget _buildAccountOverview() {
    final a = _selectedAccount;
    if (a == null) return const SizedBox.shrink();
    final equity = a.equityUsdt;
    final balance = a.balanceUsdt;
    final floating = a.floatingProfit;

    final titleSize =
        (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 2;
    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '账号资产',
            style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle())
                .copyWith(
                  color: AppFinanceStyle.labelColor,
                  fontSize:
                      (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) +
                      4,
                ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _overviewChip(
                  context,
                  '现金余额',
                  _fmt(balance),
                  titleSize: titleSize,
                  valueColor: AppFinanceStyle.profitGreenEnd,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: _overviewChip(
                  context,
                  '权益',
                  _fmt(equity),
                  valueColor: AppFinanceStyle.profitGreenEnd,
                  titleSize: titleSize,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: _overviewChip(
                  context,
                  '浮动盈亏',
                  _fmt(floating),
                  valueColor: floating >= 0
                      ? AppFinanceStyle.profitGreenEnd
                      : Colors.red,
                  titleSize: titleSize,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _overviewChip(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
    required double titleSize,
  }) {
    final color = valueColor ?? AppFinanceStyle.profitGreenEnd;
    final numberStyle =
        (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.bold,
          fontSize: titleSize,
          color: color,
        );
    return Column(
      children: [
        Text(label, style: AppFinanceStyle.labelTextStyle(context)),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [Text(value, style: numberStyle)],
        ),
      ],
    );
  }

  Widget _buildMonthEndSection() {
    if (_selectedAccount == null) return const SizedBox.shrink();
    return _glassCard(MonthEndProfitPanel(snapshots: _snapshots));
  }

  Widget _buildProfitChart() {
    final a = _selectedAccount;
    if (a == null) return const SizedBox.shrink();
    final initial = a.initialBalance;
    final current = a.currentBalance;
    final rate = a.profitPercent;
    final rateColor = rate >= 0 ? AppFinanceStyle.profitGreenEnd : Colors.red;
    final baseSize = (Theme.of(context).textTheme.titleMedium?.fontSize ?? 16)
        .toDouble();

    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '收益率',
            style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle())
                .copyWith(
                  color: AppFinanceStyle.labelColor,
                  fontSize:
                      (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) +
                      4,
                ),
          ),
          if (_snapshots.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: widget.webLayout ? 240 : 192,
              child: ProfitPercentLineChart(snapshots: _snapshots),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('期初', style: AppFinanceStyle.labelTextStyle(context)),
                  Text(
                    _fmt(initial),
                    style:
                        (Theme.of(context).textTheme.titleMedium ??
                                const TextStyle())
                            .copyWith(
                              fontWeight: FontWeight.bold,
                              color: AppFinanceStyle.profitGreenEnd,
                              fontSize: baseSize + 2,
                            ),
                  ),
                  Text(
                    ' U',
                    style:
                        (Theme.of(context).textTheme.titleMedium ??
                                const TextStyle())
                            .copyWith(
                              fontWeight: FontWeight.bold,
                              color: AppFinanceStyle.profitGreenEnd,
                              fontSize: (baseSize - 2).clamp(
                                10.0,
                                double.infinity,
                              ),
                            ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('权益', style: AppFinanceStyle.labelTextStyle(context)),
                  Text(
                    _fmt(current),
                    style:
                        (Theme.of(context).textTheme.titleMedium ??
                                const TextStyle())
                            .copyWith(
                              fontWeight: FontWeight.bold,
                              color: AppFinanceStyle.profitGreenEnd,
                              fontSize: baseSize + 2,
                            ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('收益率', style: AppFinanceStyle.labelTextStyle(context)),
                  Text(
                    _fmtPct(rate),
                    style:
                        (Theme.of(context).textTheme.titleMedium ??
                                const TextStyle())
                            .copyWith(
                              fontWeight: FontWeight.bold,
                              color: rateColor,
                              fontSize: baseSize + 2,
                            ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPositions() {
    final longs = _positions.where((p) => p.posSide == 'long').toList();
    final shorts = _positions.where((p) => p.posSide == 'short').toList();
    final allPrices = <double>[];
    for (final p in _positions) {
      if (p.avgPx > 0) allPrices.add(p.avgPx);
      final px = p.displayPrice;
      if (px > 0) allPrices.add(px);
    }
    final priceMin = allPrices.isEmpty
        ? 0.0
        : allPrices.reduce((a, b) => a < b ? a : b);
    final priceMax = allPrices.isEmpty
        ? 1.0
        : allPrices.reduce((a, b) => a > b ? a : b);
    final currentPrice = priceMax > priceMin
        ? _positions.isNotEmpty && _positions.first.displayPrice > 0
              ? _positions.first.displayPrice
              : (priceMin + priceMax) / 2
        : priceMin;

    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前持仓',
            style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle())
                .copyWith(
                  color: AppFinanceStyle.labelColor,
                  fontSize:
                      (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) +
                      4,
                ),
          ),
          const SizedBox(height: 8),
          if (_positions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _positionsLoadError ?? '暂无持仓',
                    style: TextStyle(
                      color: _positionsLoadError != null
                          ? Theme.of(context).colorScheme.error
                          : AppFinanceStyle.labelColor,
                    ),
                  ),
                  if (_positionsLoadError != null &&
                      (_positionsLoadError!.contains('403') ||
                          _positionsLoadError!.contains('白名单')))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '若本机运行 testapi 正常，请确认服务与本机同机，并在 OKX 后台将当前出口 IP 加入 API 白名单。',
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppFinanceStyle.labelColor.withValues(
                                alpha: 0.8,
                              ),
                            ) ??
                            TextStyle(
                              fontSize: 12,
                              color: AppFinanceStyle.labelColor.withValues(
                                alpha: 0.8,
                              ),
                            ),
                      ),
                    ),
                  _buildOkxDebugHint(),
                ],
              ),
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '空仓',
                        style: AppFinanceStyle.labelTextStyle(context),
                      ),
                      Text(
                        '${shorts.fold<int>(0, (s, p) => s + p.pos.abs().round())}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: AppFinanceStyle.profitGreenEnd,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      if (shorts.isNotEmpty)
                        Text(
                          '空仓浮盈 ${_fmt(shorts.fold<double>(0, (s, p) => s + p.upl))}',
                          style: TextStyle(
                            color:
                                (shorts.fold<double>(0, (s, p) => s + p.upl)) >=
                                    0
                                ? AppFinanceStyle.profitGreenEnd
                                : Colors.red,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '多仓',
                        style: AppFinanceStyle.labelTextStyle(context),
                      ),
                      Text(
                        '${longs.fold<int>(0, (s, p) => s + p.pos.round())}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: AppFinanceStyle.profitGreenEnd,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      if (longs.isNotEmpty)
                        Text(
                          '多仓浮盈 ${_fmt(longs.fold<double>(0, (s, p) => s + p.upl))}',
                          style: TextStyle(
                            color:
                                (longs.fold<double>(0, (s, p) => s + p.upl)) >=
                                    0
                                ? AppFinanceStyle.profitGreenEnd
                                : Colors.red,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_positions.map((p) => p.instId).toSet().length == 1)
              _PriceAxisBar(
                priceMin: priceMin,
                priceMax: priceMax,
                currentPrice: currentPrice,
                positions: _positions,
                labelColor: AppFinanceStyle.labelColor,
              )
            else
              ..._positions.map((p) {
                final side = p.posSide == 'long' ? '多' : '空';
                final color = p.upl >= 0
                    ? AppFinanceStyle.profitGreenEnd
                    : Colors.red;
                final small = Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppFinanceStyle.labelColor,
                );
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${p.instId} $side ${p.pos.toStringAsFixed(4)}',
                        style: small,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          Text('均价 ${_fmt(p.avgPx)}', style: small),
                          Text('现价 ${_fmt(p.displayPrice)}', style: small),
                          Text('标记 ${_fmt(p.markPx)}', style: small),
                          Text(
                            '浮盈 ${_fmt(p.upl)}',
                            style: TextStyle(color: color, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
            if (_positionsLoadError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _positionsLoadError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            _buildOkxDebugHint(),
          ],
        ],
      ),
    );
  }

  Widget _buildSeasons() {
    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '赛季盈利',
            style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle())
                .copyWith(
                  color: AppFinanceStyle.labelColor,
                  fontSize:
                      (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) +
                      4,
                ),
          ),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  '收益',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppFinanceStyle.valueColor,
                    fontSize:
                        (Theme.of(context).textTheme.bodyMedium?.fontSize ??
                            16) +
                        2,
                  ),
                  textAlign: TextAlign.left,
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(
                  '盈利率',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppFinanceStyle.valueColor,
                    fontSize:
                        (Theme.of(context).textTheme.bodyMedium?.fontSize ??
                            16) +
                        2,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const SizedBox(height: 8),
          if (_seasons.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '暂无赛季记录',
                style: TextStyle(color: AppFinanceStyle.labelColor),
              ),
            )
          else
            ..._seasons.asMap().entries.map((entry) {
              final index = entry.key + 1;
              final s = entry.value;
              final profitColor = (s.profitAmount ?? 0) >= 0
                  ? AppFinanceStyle.profitGreenEnd
                  : Colors.red;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left column
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '赛季 $index',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: AppFinanceStyle.labelColor,
                              fontSize:
                                  (Theme.of(
                                        context,
                                      ).textTheme.bodyMedium?.fontSize ??
                                      16) +
                                  4,
                            ),
                          ),
                          // 横向放 中间用 -，起始时间格式为 月-日 时:分
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Text(
                                _formatSeasonTime(s.startedAt),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: AppFinanceStyle.labelColor,
                                    ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '-',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: AppFinanceStyle.labelColor,
                                    ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _formatSeasonTime(s.stoppedAt),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: AppFinanceStyle.labelColor,
                                    ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Right column
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const SizedBox(height: 24),
                          Text(
                            _fmt(s.profitAmount ?? 0),
                            style: TextStyle(
                              color: profitColor,
                              fontWeight: FontWeight.bold,
                              fontSize:
                                  (Theme.of(
                                        context,
                                      ).textTheme.bodyMedium?.fontSize ??
                                      16) +
                                  4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const SizedBox(height: 24),
                          Text(
                            _fmtPct(s.profitPercent ?? 0),
                            style: TextStyle(
                              color: profitColor,
                              fontWeight: FontWeight.bold,
                              fontSize:
                                  (Theme.of(
                                        context,
                                      ).textTheme.bodyMedium?.fontSize ??
                                      16) +
                                  4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _PriceAxisBar extends StatelessWidget {
  const _PriceAxisBar({
    required this.priceMin,
    required this.priceMax,
    required this.currentPrice,
    required this.positions,
    this.labelColor,
  });

  final double priceMin;
  final double priceMax;
  final double currentPrice;
  final List<OkxPosition> positions;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    double min = priceMin;
    double max = priceMax;
    if (max <= min) max = min + 1;
    final range = max - min;
    final currentOffset = range > 0 ? (currentPrice - min) / range : 0.5;

    final longAvgPx = positions
        .where((p) => p.posSide == 'long')
        .map((p) => p.avgPx)
        .where((x) => x > 0);
    final shortAvgPx = positions
        .where((p) => p.posSide == 'short')
        .map((p) => p.avgPx)
        .where((x) => x > 0);

    String fmtPrice(double v) {
      if (v >= 1000) return v.toStringAsFixed(0);
      if (v >= 1) return v.toStringAsFixed(1);
      return v.toStringAsFixed(2);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 32,
          child: Stack(
            children: [
              Row(
                children: [
                  Text(
                    fmtPrice(min),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color.fromRGBO(216, 216, 216, 1),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    fmtPrice(max),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color.fromRGBO(216, 216, 216, 1),
                    ),
                  ),
                ],
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: 0,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final x =
                        constraints.maxWidth * currentOffset.clamp(0.0, 1.0);
                    return Stack(
                      children: [
                        Positioned(
                          left: x - 1,
                          top: 0,
                          bottom: 0,
                          width: 2,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                        for (final px in longAvgPx) ...[
                          if (range > 0) ...[
                            Positioned(
                              left:
                                  ((px - min) / range).clamp(0.0, 1.0) *
                                      constraints.maxWidth -
                                  6,
                              top: 4,
                              child: Icon(
                                Icons.arrow_drop_up,
                                color: Colors.green,
                                size: 24,
                              ),
                            ),
                          ],
                        ],
                        for (final px in shortAvgPx) ...[
                          if (range > 0) ...[
                            Positioned(
                              left:
                                  ((px - min) / range).clamp(0.0, 1.0) *
                                      constraints.maxWidth -
                                  6,
                              top: 4,
                              child: Icon(
                                Icons.arrow_drop_down,
                                color: Colors.red,
                                size: 24,
                              ),
                            ),
                          ],
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Text(
          '当前价格',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.blue),
        ),
      ],
    );
  }
}
