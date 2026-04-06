import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../auth/app_user_role.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import '../widgets/equity_cash_percent_line_chart.dart';
import '../widgets/month_end_profit_panel.dart';
import '../widgets/water_background.dart';

/// APK「账户收益」（客户视图）：账户选择 → 账户盈利信息总览 → 现金（日历 / 曲线 / 每日）→ 权益（日历 / 曲线 / 每日）。
class AccountProfitScreen extends StatefulWidget {
  const AccountProfitScreen({
    super.key,
    this.sharedBots = const [],
    this.initialBotId,
    this.periodicRefreshActive = true,
  });

  /// 由 MainScreen 下发的交易账户列表，与账户管理同源，保证下拉框有数据
  final List<UnifiedTradingBot> sharedBots;

  /// 进入页面时默认选中的交易账户（例如从账户管理列表点入）
  final String? initialBotId;

  /// 为 false 时不启动定时刷新（例如嵌在 MainScreen 非当前 Tab 时避免后台请求）
  final bool periodicRefreshActive;

  @override
  State<AccountProfitScreen> createState() => _AccountProfitScreenState();
}

class _AccountProfitScreenState extends State<AccountProfitScreen> {
  final _prefs = SecurePrefs();
  List<AccountProfit> _accounts = [];
  List<UnifiedTradingBot> _bots = [];
  String? _selectedBotId;
  List<BotProfitSnapshot> _snapshots = [];
  bool _loading = true;
  String? _error;
  Timer? _autoRefreshTimer;
  static const String _defaultBotId = 'simpleserver';
  static const double _kUnifiedChartBandHeight = 420;

  DateTime? _equityMetricsMonth;
  DateTime? _cashMetricsMonth;
  Map<int, int>? _equityCalendarCloseCounts;
  Map<int, int>? _cashCalendarCloseCounts;
  final TextEditingController _noDropdownAccountController =
      TextEditingController();

  /// 保持当前选中账户，拉取最新收益、曲线、持仓与赛季（用于定时刷新与下拉切换后的全量刷新）
  Future<void> _refreshLatestData() async {
    if (!mounted || _loading) return;
    final list = _bots.isNotEmpty ? _bots : widget.sharedBots;
    final role = await _prefs.getAppUserRole();
    final isCustomer = role == AppUserRole.customer;
    final botId = _selectedBotId ??
        (list.isNotEmpty ? list.first.tradingbotId : null) ??
        (isCustomer ? null : _defaultBotId);
    if (botId == null || botId.isEmpty) return;
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
        _equityMetricsMonth = null;
        _cashMetricsMonth = null;
      });
      unawaited(_syncCalendarCloseCounts());
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

      final role = await _prefs.getAppUserRole();
      final isCustomer = role == AppUserRole.customer;

      // 优先 MainScreen 下发的列表；否则本页拉取（与账户管理同源）
      List<UnifiedTradingBot> bots = List.from(widget.sharedBots);
      if (bots.isEmpty) {
        final botsResp = await api.getTradingBots();
        bots = botsResp.botList;
      }
      final initial = widget.initialBotId?.trim();
      if (initial != null && initial.isNotEmpty && !bots.any((b) => b.tradingbotId == initial)) {
        // 客户不得以 URL/参数注入未绑定账户；交易员/管理员可临时查看指定 id
        if (!isCustomer) {
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
      final String? botId;
      if (initial != null &&
          initial.isNotEmpty &&
          bots.any((b) => b.tradingbotId == initial)) {
        botId = initial;
      } else if (bots.isNotEmpty) {
        botId = bots.first.tradingbotId;
      } else {
        botId = isCustomer ? null : _defaultBotId;
      }

      if (!mounted) return;
      // 阶段一：一有账户列表就结束全屏 loading，下拉框可立即显示
      setState(() {
        _bots = bots;
        _selectedBotId = botId;
        _loading = false;
      });

      // 阶段二：账户收益 + 历史（不经过 OKX 直连，通常较快）
      try {
        final profitResp = await api.getAccountProfit();
        final historyResp = (botId != null && botId.isNotEmpty)
            ? await api.getBotProfitHistory(botId, limit: 500)
            : BotProfitHistoryResponse(
                success: true,
                botId: '',
                snapshots: const [],
              );
        if (!mounted) return;
        setState(() {
          _accounts = profitResp.accounts ?? [];
          _snapshots = historyResp.snapshots;
          _equityMetricsMonth = null;
          _cashMetricsMonth = null;
        });
        unawaited(_syncCalendarCloseCounts());
      } catch (e) {
        if (mounted) {
          setState(() => _error = '收益/历史加载失败: $e');
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
      ]);
      if (!mounted) return;
      final profitResp = results[0] as AccountProfitResponse;
      final historyResp = results[1] as BotProfitHistoryResponse;
      setState(() {
        _accounts = profitResp.accounts ?? [];
        _snapshots = historyResp.snapshots;
        _error = null;
        _equityMetricsMonth = null;
        _cashMetricsMonth = null;
      });
      unawaited(_syncCalendarCloseCounts());
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
    _noDropdownAccountController.dispose();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  String _fmt(double v) => formatUiInteger(v);
  String _fmtPct(double v) => formatUiPercentLabel(v);

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

  UnifiedTradingBot? get _currentUnifiedBot {
    final id = _selectedBotId;
    if (id == null || id.isEmpty) return null;
    for (final b in _effectiveBots) {
      if (b.tradingbotId == id) return b;
    }
    return null;
  }

  DateTime _equityMonthFor(List<BotProfitSnapshot> snap) {
    final seed = _equityMetricsMonth ?? focusedMonthFromProfitSnapshots(snap);
    return clampMonthToSnapshots(snap, seed);
  }

  DateTime _cashMonthFor(List<BotProfitSnapshot> snap) {
    final seed = _cashMetricsMonth ?? focusedMonthFromProfitSnapshots(snap);
    return clampMonthToSnapshots(snap, seed);
  }

  Future<void> _syncCalendarCloseCounts() async {
    final list = _bots.isNotEmpty ? _bots : widget.sharedBots;
    final botId = _selectedBotId ??
        (list.isNotEmpty ? list.first.tradingbotId : null) ??
        _defaultBotId;
    final snap = _snapshots;
    if (snap.isEmpty) {
      if (!mounted) return;
      setState(() {
        _equityCalendarCloseCounts = null;
        _cashCalendarCloseCounts = null;
      });
      return;
    }
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final eq = _equityMonthFor(snap);
      final cash = _cashMonthFor(snap);
      if (eq.year == cash.year && eq.month == cash.month) {
        final r = await api.getDailyRealizedPnl(botId, eq.year, eq.month);
        if (!mounted) return;
        if (!r.success) {
          setState(() {
            _equityCalendarCloseCounts = null;
            _cashCalendarCloseCounts = null;
          });
          return;
        }
        final m = dailyCloseCountsMapForMonth(r.days, eq.year, eq.month);
        setState(() {
          _equityCalendarCloseCounts = m;
          _cashCalendarCloseCounts = m;
        });
      } else {
        final rEq = await api.getDailyRealizedPnl(botId, eq.year, eq.month);
        final rCash = await api.getDailyRealizedPnl(botId, cash.year, cash.month);
        if (!mounted) return;
        setState(() {
          _equityCalendarCloseCounts = rEq.success
              ? dailyCloseCountsMapForMonth(rEq.days, eq.year, eq.month)
              : null;
          _cashCalendarCloseCounts = rCash.success
              ? dailyCloseCountsMapForMonth(rCash.days, cash.year, cash.month)
              : null;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _equityCalendarCloseCounts = null;
        _cashCalendarCloseCounts = null;
      });
    }
  }

  void _syncNoDropdownAccountLabel() {
    if (_effectiveBots.isNotEmpty) return;
    final a = _selectedAccount;
    final text = a == null
        ? ''
        : (a.exchangeAccount.trim().isNotEmpty ? a.exchangeAccount : a.botId);
    if (_noDropdownAccountController.text != text) {
      _noDropdownAccountController.text = text;
    }
  }

  Widget _buildMetricsMonthNav({
    required List<BotProfitSnapshot> snapshots,
    required DateTime month,
    required ValueChanged<DateTime> onMonthChanged,
  }) {
    if (snapshots.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        Text(
          '查看月份',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: '上一月',
          icon: const Icon(Icons.chevron_left, color: AppFinanceStyle.valueColor),
          onPressed: () {
            onMonthChanged(
              clampMonthToSnapshots(
                snapshots,
                DateTime(month.year, month.month - 1),
              ),
            );
          },
        ),
        Text(
          '${month.year}-${month.month.toString().padLeft(2, '0')}',
          style: TextStyle(
            color: AppFinanceStyle.valueColor,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        IconButton(
          tooltip: '下一月',
          icon: const Icon(Icons.chevron_right, color: AppFinanceStyle.valueColor),
          onPressed: () {
            onMonthChanged(
              clampMonthToSnapshots(
                snapshots,
                DateTime(month.year, month.month + 1),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildNoDropdownAccountField() {
    final a = _selectedAccount;
    if (a == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.of(context).size.width * 0.92).clamp(200.0, 520.0),
          minHeight: kMinInteractiveDimension,
        ),
        child: _glassCard(
          TextField(
            readOnly: true,
            controller: _noDropdownAccountController,
            style: const TextStyle(color: AppFinanceStyle.valueColor),
            decoration: InputDecoration(
              isDense: true,
              labelText: '当前账户',
              labelStyle: AppFinanceStyle.labelTextStyle(context),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        ),
      ),
    );
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

  Widget _buildAccountPageContent() {
    return Column(
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
        ] else if (_selectedAccount != null) ...[
          _buildNoDropdownAccountField(),
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
        _buildProfitOverview(),
        const SizedBox(height: 28),
        _buildCashCustomerSections(),
        const SizedBox(height: 28),
        _buildEquityCustomerSections(),
      ],
    );
  }

  Widget _buildBodyScrollable() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
      children: [
        _buildAccountPageContent(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncNoDropdownAccountLabel();
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '账户收益',
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

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle())
          .copyWith(
            color: AppFinanceStyle.labelColor,
            fontSize:
                (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 2,
            fontWeight: FontWeight.w600,
          ),
    );
  }

  Widget _partHeading(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: AppFinanceStyle.labelTextStyle(context).copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
      ),
    );
  }

  /// 1. 账户盈利信息总览（与 Web 账户画像核心指标一致，不含机器人/交易所细节）
  Widget _buildProfitOverview() {
    final a = _selectedAccount;
    if (a == null) return const SizedBox.shrink();
    final bot = _currentUnifiedBot;
    final equity = a.equityUsdt;
    final balance = a.balanceUsdt;
    final floating = a.floatingProfit;
    final rate = a.profitPercent;
    final rateColor = rate >= 0 ? AppFinanceStyle.profitGreenEnd : Colors.red;
    final titleSize =
        (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 2;

    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('账户盈利信息总览'),
          const SizedBox(height: 12),
          Text(
            bot?.tradingbotName ?? bot?.tradingbotId ?? a.botId,
            style: (Theme.of(context).textTheme.titleMedium ?? const TextStyle())
                .copyWith(
              color: AppFinanceStyle.valueColor,
              fontWeight: FontWeight.w600,
              fontSize: 17,
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < 520;
              final chipBal = _overviewChip(
                context,
                '现金余额',
                _fmt(balance),
                titleSize: titleSize,
                valueColor: AppFinanceStyle.profitGreenEnd,
              );
              final chipEq = _overviewChip(
                context,
                '权益',
                _fmt(equity),
                titleSize: titleSize,
                valueColor: AppFinanceStyle.profitGreenEnd,
              );
              final chipFl = _overviewChip(
                context,
                '浮动盈亏',
                _fmt(floating),
                titleSize: titleSize,
                valueColor: floating >= 0
                    ? AppFinanceStyle.profitGreenEnd
                    : Colors.red,
              );
              final chipIni = _overviewChip(
                context,
                '期初',
                _fmt(a.initialBalance),
                titleSize: titleSize,
                valueColor: AppFinanceStyle.profitGreenEnd,
              );
              final chipRate = _overviewChip(
                context,
                '收益率',
                _fmtPct(rate),
                titleSize: titleSize,
                valueColor: rateColor,
              );
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    chipBal,
                    const SizedBox(height: 12),
                    chipEq,
                    const SizedBox(height: 12),
                    chipFl,
                    const SizedBox(height: 12),
                    chipIni,
                    const SizedBox(height: 12),
                    chipRate,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: chipBal),
                      const SizedBox(width: 16),
                      Expanded(child: chipEq),
                      const SizedBox(width: 16),
                      Expanded(child: chipFl),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: chipIni),
                      const SizedBox(width: 16),
                      Expanded(child: chipRate),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// 2–4：现金日历、现金曲线、每日现金（共用「查看月份」）
  Widget _buildCashCustomerSections() {
    if (_selectedAccount == null) return const SizedBox.shrink();
    final snap = _snapshots;
    final month = _cashMonthFor(snap);
    void setCashMonth(DateTime d) {
      setState(() => _cashMetricsMonth = clampMonthToSnapshots(snap, d));
      unawaited(_syncCalendarCloseCounts());
    }
    final calCap = _kUnifiedChartBandHeight;
    final plotH = calendarGridPixelHeightForCap(calCap, compact: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _partHeading('现金日历视图'),
        if (snap.isNotEmpty) ...[
          _buildMetricsMonthNav(
            snapshots: snap,
            month: month,
            onMonthChanged: setCashMonth,
          ),
          const SizedBox(height: 12),
        ],
        _glassCard(
          MonthEndValueCalendarPanel(
            snapshots: snap,
            title: '',
            description:
                '按日展示：当日最后一条快照现金余额相对前一有效时点的变化。右下角平仓笔数为 UTC 自然日历史平仓汇总（与盈亏数值口径不同）。',
            valueAt: (s) => s.currentBalance,
            emptyMessage: '暂无历史快照，无法统计月度现金余额',
            showMonthNavigator: false,
            focusedMonth: month,
            onFocusedMonthChanged: setCashMonth,
            gridMaxHeight: calCap,
            dailyCloseCounts: _cashCalendarCloseCounts,
          ),
        ),
        const SizedBox(height: 20),
        _partHeading('现金曲线'),
        _glassCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '相对收益率（现金）%',
                style: AppFinanceStyle.labelTextStyle(context)
                    .copyWith(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: plotH,
                child: SnapshotPercentLineChart(
                  snapshots: snap,
                  series: SnapshotReturnSeries.cash,
                  compact: true,
                  focusedMonth: month,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _partHeading('每日现金'),
        _glassCard(
          MonthEndValueBarPanel(
            snapshots: snap,
            title: '',
            description:
                '按日展示：当日最后一条快照现金余额相对前一有效时点的变化（与日历一致）。',
            valueAt: (s) => s.currentBalance,
            emptyMessage: '暂无历史快照，无法统计月度现金余额',
            showMonthNavigator: false,
            selectedEndMonth: month,
            onSelectedEndMonthChanged: setCashMonth,
            barChartHeight: plotH,
            maxBars: 8,
            useDailyBarsForEndMonth: true,
          ),
        ),
      ],
    );
  }

  /// 5–7：权益日历、权益曲线、每日权益（共用「查看月份」，与现金月份可独立切换）
  Widget _buildEquityCustomerSections() {
    if (_selectedAccount == null) return const SizedBox.shrink();
    final snap = _snapshots;
    final month = _equityMonthFor(snap);
    void setEquityMonth(DateTime d) {
      setState(() => _equityMetricsMonth = clampMonthToSnapshots(snap, d));
      unawaited(_syncCalendarCloseCounts());
    }
    final calCap = _kUnifiedChartBandHeight;
    final plotH = calendarGridPixelHeightForCap(calCap, compact: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _partHeading('权益日历视图'),
        if (snap.isNotEmpty) ...[
          _buildMetricsMonthNav(
            snapshots: snap,
            month: month,
            onMonthChanged: setEquityMonth,
          ),
          const SizedBox(height: 12),
        ],
        _glassCard(
          MonthEndValueCalendarPanel(
            snapshots: snap,
            title: '',
            description:
                '按日展示：当日最后一条快照权益相对前一有效时点的变化。右下角平仓笔数为 UTC 自然日历史平仓汇总（与盈亏数值口径不同）。',
            valueAt: (s) => s.equityUsdt,
            emptyMessage: '暂无历史快照，无法统计月度权益',
            showMonthNavigator: false,
            focusedMonth: month,
            onFocusedMonthChanged: setEquityMonth,
            gridMaxHeight: calCap,
            dailyCloseCounts: _equityCalendarCloseCounts,
          ),
        ),
        const SizedBox(height: 20),
        _partHeading('权益曲线'),
        _glassCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '相对收益率（权益）%',
                style: AppFinanceStyle.labelTextStyle(context)
                    .copyWith(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: plotH,
                child: SnapshotPercentLineChart(
                  snapshots: snap,
                  series: SnapshotReturnSeries.equity,
                  compact: true,
                  focusedMonth: month,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _partHeading('每日权益'),
        _glassCard(
          MonthEndValueBarPanel(
            snapshots: snap,
            title: '',
            description:
                '按日展示：当日最后一条快照权益相对前一有效时点的变化（与日历一致）。',
            valueAt: (s) => s.equityUsdt,
            emptyMessage: '暂无历史快照，无法统计月度权益',
            showMonthNavigator: false,
            selectedEndMonth: month,
            onSelectedEndMonthChanged: setEquityMonth,
            barChartHeight: plotH,
            maxBars: 8,
            useDailyBarsForEndMonth: true,
          ),
        ),
      ],
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

}
