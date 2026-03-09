import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../widgets/water_background.dart';

class AccountProfitScreen extends StatefulWidget {
  const AccountProfitScreen({super.key, this.sharedBots = const []});

  /// 由 MainScreen 下发的机器人列表，与策略管理同源，保证下拉框有数据
  final List<UnifiedTradingBot> sharedBots;

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
  Timer? _positionTimer;
  static const String _defaultBotId = 'simpleserver';

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);

      // 优先使用 MainScreen 下发的列表，与策略管理同源，避免本页 getTradingBots 空或失败导致无下拉框
      List<UnifiedTradingBot> bots = widget.sharedBots;
      if (bots.isEmpty) {
        final botsResp = await api.getTradingBots();
        bots = botsResp.botList;
      }
      final botId = bots.isNotEmpty ? bots.first.tradingbotId : _defaultBotId;

      // 并行拉取收益、历史、持仓、赛季，再一次性 setState，避免先出列表再迟 2 秒出数据（与策略管理页同因）
      final profitFuture = api.getAccountProfit();
      final historyFuture = api.getBotProfitHistory(botId, limit: 500);
      final positionsFuture = api.getTradingbotPositions(botId);
      final seasonsFuture = api.getTradingbotSeasons(botId, limit: 50);

      final profitResp = await profitFuture;
      final historyResp = await historyFuture;
      final positionsResp = await positionsFuture;
      final seasonsResp = await seasonsFuture;

      if (!mounted) return;
      setState(() {
        _bots = bots;
        _selectedBotId = botId;
        _accounts = profitResp.accounts ?? [];
        _snapshots = historyResp.snapshots;
        _positions = positionsResp.positions;
        _positionsLoadError = positionsResp.positionsError;
        _seasons = seasonsResp.seasons;
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

  Future<void> _loadPositionsOnly() async {
    final firstBotId = _bots.isNotEmpty
        ? _bots.first.tradingbotId
        : 'simpleserver-lhg';
    final botId = _selectedBotId ?? firstBotId;
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final positionsResp = await api.getTradingbotPositions(botId);
      if (!mounted) return;
      setState(() {
        _positions = positionsResp.positions;
        _positionsLoadError = positionsResp.positionsError;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _positionsLoadError = '持仓更新失败，请下拉刷新');
    }
  }

  Future<void> _loadForBot(String botId) async {
    if (botId == _selectedBotId) return;
    setState(() => _selectedBotId = botId);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final historyResp = await api.getBotProfitHistory(botId, limit: 500);
      final seasonsResp = await api.getTradingbotSeasons(botId, limit: 50);
      final positionsResp = await api.getTradingbotPositions(botId);
      if (!mounted) return;
      setState(() {
        _snapshots = historyResp.snapshots;
        _seasons = seasonsResp.seasons;
        _positions = positionsResp.positions;
        _positionsLoadError = positionsResp.positionsError;
      });
    } catch (_) {}
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
    _positionTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _loadPositionsOnly(),
    );
  }

  @override
  void didUpdateWidget(covariant AccountProfitScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    _positionTimer?.cancel();
    super.dispose();
  }

  String _fmt(double v) => v.toStringAsFixed(2);
  String _fmtPct(double v) => '${v.toStringAsFixed(2)}%';

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
    if (list.length == 1) {
      return Align(
        alignment: Alignment.centerLeft,
        child: _glassCard(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              list.first.tradingbotName ?? list.first.tradingbotId,
              style: const TextStyle(color: AppFinanceStyle.valueColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: (MediaQuery.of(context).size.width * 0.45).clamp(160.0, 280.0),
        height: kMinInteractiveDimension,
        child: _glassCard(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '机器人收益',
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
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
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
                            '暂无账户数据，请确认后端已配置交易机器人',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ),
                    _buildAccountOverview(),
                    const SizedBox(height: 32),
                    _buildProfitChart(),
                    const SizedBox(height: 32),
                    _buildPositions(),
                    const SizedBox(height: 32),
                    _buildSeasons(),
                  ],
                ),
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
                  '权益',
                  _fmt(equity),
                  titleSize: titleSize,
                  valueColor: AppFinanceStyle.profitGreenEnd,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: _overviewChip(
                  context,
                  '余额',
                  _fmt(balance),
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
    final unitStyle =
        (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.bold,
          fontSize: (titleSize - 2).clamp(10.0, double.infinity),
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
              height: 192,
              child: _ProfitPercentLineChart(snapshots: _snapshots),
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
                  Text('当前', style: AppFinanceStyle.labelTextStyle(context)),
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
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${p.instId} $side ${p.pos.toStringAsFixed(4)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppFinanceStyle.labelColor,
                        ),
                      ),
                      Text(
                        '均价 ${_fmt(p.avgPx)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppFinanceStyle.labelColor,
                        ),
                      ),
                      Text(
                        '标记 ${_fmt(p.markPx)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppFinanceStyle.labelColor,
                        ),
                      ),
                      Text(
                        _fmt(p.upl),
                        style: TextStyle(color: color, fontSize: 12),
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
              final startStr = s.startedAt != null && s.startedAt!.length >= 19
                  ? s.startedAt!.substring(0, 19).replaceAll('T', ' ')
                  : (s.startedAt ?? '-');
              final stopStr = s.stoppedAt != null && s.stoppedAt!.length >= 19
                  ? s.stoppedAt!.substring(0, 19).replaceAll('T', ' ')
                  : (s.stoppedAt ?? '-');
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

/// 盈利率曲线（参考策略管理）：用 profitPercent 画线，盈利部分更明显
class _ProfitPercentLineChart extends StatelessWidget {
  const _ProfitPercentLineChart({required this.snapshots});

  final List<BotProfitSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) return const SizedBox.shrink();
    final spots = <FlSpot>[];
    double minY = 0, maxY = 0;
    for (var i = 0; i < snapshots.length; i++) {
      final p = snapshots[i].profitPercent;
      spots.add(FlSpot(i.toDouble(), p));
      if (p < minY) minY = p;
      if (p > maxY) maxY = p;
    }
    if (minY == maxY) {
      minY = minY - 1;
      maxY = maxY + 1;
    }
    final isPositive =
        snapshots.isNotEmpty && (snapshots.last.profitPercent >= 0);
    final lineColor = isPositive ? AppFinanceStyle.profitGreenEnd : Colors.red;
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (snapshots.length - 1).clamp(0, double.infinity).toDouble(),
        minY: minY - 2,
        maxY: maxY + 2,
        gridData: FlGridData(show: false),
        titlesData: FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: lineColor,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: (isPositive ? AppFinanceStyle.profitGreenEnd : Colors.red)
                  .withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 150),
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
