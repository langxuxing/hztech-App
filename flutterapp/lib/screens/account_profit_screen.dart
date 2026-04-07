import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../auth/app_user_role.dart';
import '../secure/prefs.dart';
import '../services/okx_public_ticker_ws.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import '../widgets/equity_cash_percent_line_chart.dart';
import '../widgets/month_end_profit_panel.dart';
import '../widgets/water_background.dart';

/// APK「账户收益」（客户视图）：账户选择 → 账户盈利总览 → 当前持仓 → 现金（日历 / 曲线 / 每日）→ 权益（日历 / 曲线 / 每日）。
class AccountProfitScreen extends StatefulWidget {
  const AccountProfitScreen({
    super.key,
    this.sharedBots = const [],
    this.initialBotId,
    this.periodicRefreshActive = true,
    this.showRealtimeAppBarTitle = false,
  });

  /// 由 MainScreen 下发的交易账户列表，与账户管理同源，保证下拉框有数据
  final List<UnifiedTradingBot> sharedBots;

  /// 进入页面时默认选中的交易账户（例如从账户管理列表点入）
  final String? initialBotId;

  /// 为 false 时不启动定时刷新（例如嵌在 MainScreen 非当前 Tab 时避免后台请求）
  final bool periodicRefreshActive;

  /// MainScreen 客户主导航为「实时收益」时置 true，AppBar 标题与底栏一致（不必等本页 `_load` 读角色）。
  final bool showRealtimeAppBarTitle;

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
  OkxPublicTickerWs? _tickerWs;
  StreamSubscription<double>? _tickerSub;
  double? _liveLastPx;
  String? _tickerSubscribedInstId;
  List<OkxPosition> _positions = [];
  String? _positionsLoadError;
  static const String _defaultBotId = 'simpleserver';
  static const double _kUnifiedChartBandHeight = 210;
  static const double _kLineBarHeightFactor = 0.7;

  /// 与 [MonthEndValueCalendarPanel] / [calendarGridPixelHeightForCap] 中非 compact 的
  /// 表头、行数、行间距一致：在折线/柱图高度 [lineBarPlotHeight] 下推出基准单元格高度，
  /// 再按 4 倍（相对基准为原先「双倍」预算再增高 100%）作为日历总高度预算。
  double _calendarGridMaxHeightDoubled(double lineBarPlotHeight) {
    const headerH = 22.0;
    const rows = 6.0;
    const rowSpacing = 6.0;
    final overhead = headerH + rowSpacing + rows * rowSpacing;
    final baseCell = ((lineBarPlotHeight - overhead) / rows).clamp(28.0, 58.0);
    final tallCell = baseCell * 4;
    return headerH + rowSpacing + rows * (tallCell + rowSpacing);
  }

  DateTime? _equityMetricsMonth;
  DateTime? _cashMetricsMonth;
  Map<int, int>? _equityCalendarCloseCounts;
  Map<int, int>? _cashCalendarCloseCounts;
  final TextEditingController _noDropdownAccountController =
      TextEditingController();

  /// 与 `_load` 同步，用于客户视图下禁用账户下拉、仅只读展示已绑定账户。
  AppUserRole _appUserRole = AppUserRole.trader;

  /// 切换账户时递增，用于丢弃过期的异步结果与日历同步。
  int _accountSwitchGeneration = 0;

  /// 立即断开 OKX 公共 ticker WS（切换账户须先于新请求调用，避免旧连接推送干扰）。
  void _disconnectOkxPublicTicker() {
    _tickerSub?.cancel();
    _tickerSub = null;
    _tickerWs?.dispose();
    _tickerWs = null;
    _tickerSubscribedInstId = null;
    _liveLastPx = null;
  }

  /// 保持当前选中账户，拉取最新收益、曲线与持仓（用于定时刷新与下拉切换后的全量刷新）
  Future<void> _refreshLatestData() async {
    if (!mounted || _loading) return;
    final list = _bots.isNotEmpty ? _bots : widget.sharedBots;
    final role = await _prefs.getAppUserRole();
    final isCustomer = role == AppUserRole.customer;
    final botId =
        _selectedBotId ??
        (list.isNotEmpty ? list.first.tradingbotId : null) ??
        (isCustomer ? null : _defaultBotId);
    if (botId == null || botId.isEmpty) return;
    final g = _accountSwitchGeneration;
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      if (!mounted || g != _accountSwitchGeneration) return;
      final api = ApiClient(baseUrl, token: token);
      final batch = await Future.wait([
        api.getAccountProfit(),
        api.getBotProfitHistory(botId),
        api.getTradingbotPositions(botId),
      ]);
      if (!mounted || g != _accountSwitchGeneration) return;
      final profitResp = batch[0] as AccountProfitResponse;
      final historyResp = batch[1] as BotProfitHistoryResponse;
      final posResp = batch[2] as OkxPositionsResponse;
      setState(() {
        _accounts = profitResp.accounts ?? [];
        _snapshots = historyResp.snapshots;
        _positions = posResp.positions;
        _positionsLoadError = posResp.positionsError;
        _equityMetricsMonth = null;
        _cashMetricsMonth = null;
      });
      unawaited(_syncCalendarCloseCounts());
      _syncOkxTickerSubscription();
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
      final role = await _prefs.getAppUserRole();
      if (!mounted) return;
      setState(() => _appUserRole = role);
      final isCustomer = role == AppUserRole.customer;

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
      if (initial != null &&
          initial.isNotEmpty &&
          !bots.any((b) => b.tradingbotId == initial)) {
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
      // 阶段一：一有账户列表就结束全屏 loading；客户仅只读展示绑定账户，不显示下拉
      setState(() {
        _bots = bots;
        _selectedBotId = botId;
        _loading = false;
      });

      // 阶段二：收益、历史、持仓并行（缩短首屏等待）
      try {
        if (botId != null && botId.isNotEmpty) {
          final out = await Future.wait([
            api.getAccountProfit(),
            api.getBotProfitHistory(botId),
            api.getTradingbotPositions(botId),
          ]);
          if (!mounted) return;
          final profitResp = out[0] as AccountProfitResponse;
          final historyResp = out[1] as BotProfitHistoryResponse;
          final posResp = out[2] as OkxPositionsResponse;
          setState(() {
            _accounts = profitResp.accounts ?? [];
            _snapshots = historyResp.snapshots;
            _positions = posResp.positions;
            _positionsLoadError = posResp.positionsError;
            _equityMetricsMonth = null;
            _cashMetricsMonth = null;
          });
          unawaited(_syncCalendarCloseCounts());
          _syncOkxTickerSubscription();
        } else {
          final profitResp = await api.getAccountProfit();
          if (!mounted) return;
          setState(() {
            _accounts = profitResp.accounts ?? [];
            _snapshots = const [];
            _equityMetricsMonth = null;
            _cashMetricsMonth = null;
          });
          unawaited(_syncCalendarCloseCounts());
        }
      } catch (e) {
        if (mounted) {
          setState(() => _error = '收益/历史/持仓加载失败: $e');
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
    _disconnectOkxPublicTicker();
    final g = ++_accountSwitchGeneration;
    setState(() {
      _selectedBotId = botId;
      _positions = [];
      _positionsLoadError = null;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      if (!mounted || g != _accountSwitchGeneration) return;
      final api = ApiClient(baseUrl, token: token);

      final phase1 = await Future.wait([
        api.getAccountProfit(),
        api.getBotProfitHistory(botId),
      ]);
      if (!mounted || g != _accountSwitchGeneration) return;
      final profitResp = phase1[0] as AccountProfitResponse;
      final historyResp = phase1[1] as BotProfitHistoryResponse;
      setState(() {
        _accounts = profitResp.accounts ?? [];
        _snapshots = historyResp.snapshots;
        _equityMetricsMonth = null;
        _cashMetricsMonth = null;
      });
      unawaited(_syncCalendarCloseCounts());

      final phase2 = await api.getTradingbotPositions(botId);
      if (!mounted || g != _accountSwitchGeneration) return;
      setState(() {
        _positions = phase2.positions;
        _positionsLoadError = phase2.positionsError;
      });
      _syncOkxTickerSubscription();
    } catch (e) {
      if (mounted && g == _accountSwitchGeneration) {
        setState(() => _error = '切换账户后加载失败: $e');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _syncAutoRefreshTimer();
  }

  void _syncAutoRefreshTimer() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    if (!widget.periodicRefreshActive) return;
    _autoRefreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshLatestData(),
    );
  }

  @override
  void didUpdateWidget(covariant AccountProfitScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.periodicRefreshActive != widget.periodicRefreshActive) {
      _syncAutoRefreshTimer();
      if (!widget.periodicRefreshActive) {
        _disconnectOkxPublicTicker();
        if (mounted) setState(() {});
      } else if (mounted) {
        _syncOkxTickerSubscription();
      }
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
    _disconnectOkxPublicTicker();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  /// 仅单合约持仓时连接 OKX 公共 WS 推送现价；切换标的或清空持仓时断开（与 Web 账户画像一致）。
  void _syncOkxTickerSubscription() {
    if (!mounted) return;
    final ids = _positions
        .map((e) => e.instId)
        .where((e) => e.isNotEmpty)
        .toSet();
    final singleInst = ids.length == 1 ? ids.first : null;

    if (singleInst == null) {
      final had = _liveLastPx != null;
      _disconnectOkxPublicTicker();
      if (had) {
        setState(() {});
      }
      return;
    }

    if (_tickerSubscribedInstId == singleInst &&
        _tickerWs != null &&
        _tickerSub != null) {
      return;
    }

    final prevInst = _tickerSubscribedInstId;
    _tickerSub?.cancel();
    _tickerSub = null;
    _tickerWs?.dispose();
    _tickerWs = OkxPublicTickerWs();
    _tickerSubscribedInstId = singleInst;
    if (prevInst != singleInst) {
      _liveLastPx = null;
    }
    _tickerWs!.subscribe(singleInst);
    final stream = _tickerWs!.priceStream;
    if (stream != null) {
      _tickerSub = stream.listen((px) {
        if (mounted) setState(() => _liveLastPx = px);
      });
    }
  }

  double _dynUplFor(OkxPosition p, double last) {
    final mark = p.markPx;
    final avg = p.avgPx;
    final denom = mark - avg;
    if (denom.abs() < 1e-12) return p.upl;
    return p.upl * (last - avg) / denom;
  }

  double _totalDynUpl(Iterable<OkxPosition> ps, double last) =>
      ps.fold<double>(0, (s, p) => s + _dynUplFor(p, last));

  double _singleInstQuotePx() {
    for (final p in _positions) {
      final d = p.displayPrice;
      if (d > 0) return d;
    }
    for (final p in _positions) {
      if (p.markPx > 0) return p.markPx;
    }
    return 0;
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

  DateTime _equityMonthFor(List<BotProfitSnapshot> snap) {
    final seed = _equityMetricsMonth ?? focusedMonthFromProfitSnapshots(snap);
    return clampMonthToSnapshots(snap, seed);
  }

  DateTime _cashMonthFor(List<BotProfitSnapshot> snap) {
    final seed = _cashMetricsMonth ?? focusedMonthFromProfitSnapshots(snap);
    return clampMonthToSnapshots(snap, seed);
  }

  Future<void> _syncCalendarCloseCounts() async {
    final gen = _accountSwitchGeneration;
    final list = _bots.isNotEmpty ? _bots : widget.sharedBots;
    final botId =
        _selectedBotId ??
        (list.isNotEmpty ? list.first.tradingbotId : null) ??
        _defaultBotId;
    final snap = _snapshots;
    if (snap.isEmpty) {
      if (!mounted || gen != _accountSwitchGeneration) return;
      setState(() {
        _equityCalendarCloseCounts = null;
        _cashCalendarCloseCounts = null;
      });
      return;
    }
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      if (!mounted || gen != _accountSwitchGeneration) return;
      final api = ApiClient(baseUrl, token: token);
      final eq = _equityMonthFor(snap);
      final cash = _cashMonthFor(snap);
      if (eq.year == cash.year && eq.month == cash.month) {
        final r = await api.getDailyRealizedPnl(botId, eq.year, eq.month);
        if (!mounted || gen != _accountSwitchGeneration) return;
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
        final rCash = await api.getDailyRealizedPnl(
          botId,
          cash.year,
          cash.month,
        );
        if (!mounted || gen != _accountSwitchGeneration) return;
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
      if (!mounted || gen != _accountSwitchGeneration) return;
      setState(() {
        _equityCalendarCloseCounts = null;
        _cashCalendarCloseCounts = null;
      });
    }
  }

  void _syncNoDropdownAccountLabel() {
    final isCustomer = _appUserRole == AppUserRole.customer;
    // 非客户且存在 bot 列表时用下拉框，此处不维护只读文案
    if (!isCustomer && _effectiveBots.isNotEmpty) return;

    final a = _selectedAccount;
    String text;
    if (a != null) {
      text = a.exchangeAccount.trim().isNotEmpty ? a.exchangeAccount : a.botId;
    } else if (isCustomer && _effectiveBots.isNotEmpty) {
      final id = _selectedBotId;
      final idx = (id != null && id.isNotEmpty)
          ? _effectiveBots.indexWhere((b) => b.tradingbotId == id)
          : -1;
      final bot = idx >= 0 ? _effectiveBots[idx] : _effectiveBots.first;
      final name = bot.tradingbotName?.trim();
      text = (name != null && name.isNotEmpty) ? name : bot.tradingbotId;
    } else {
      text = '';
    }
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
          style: AppFinanceStyle.labelTextStyle(
            context,
          ).copyWith(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const Spacer(),
        IconButton(
          tooltip: '上一月',
          icon: const Icon(
            Icons.chevron_left,
            color: AppFinanceStyle.valueColor,
          ),
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
          icon: const Icon(
            Icons.chevron_right,
            color: AppFinanceStyle.valueColor,
          ),
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
    final isCustomer = _appUserRole == AppUserRole.customer;
    if (a == null && !(isCustomer && _effectiveBots.isNotEmpty)) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.of(context).size.width * 0.92).clamp(
            200.0,
            520.0,
          ),
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
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 8,
              ),
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
    // 交易员/管理员：无论 1 个或多个交易账户都使用 DropdownButton；客户仅用只读展示
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.of(context).size.width * 0.45).clamp(
            160.0,
            280.0,
          ),
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
        if (_appUserRole != AppUserRole.customer &&
            _effectiveBots.isNotEmpty) ...[
          _buildBotSelector(),
          const SizedBox(height: 24),
        ] else if ((_appUserRole == AppUserRole.customer &&
                _effectiveBots.isNotEmpty) ||
            _selectedAccount != null) ...[
          _buildNoDropdownAccountField(),
          const SizedBox(height: 24),
        ],
        if (_accounts.isEmpty && _error == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '暂无账户数据，请确认后端 accounts 已配置交易账户',
                style: TextStyle(color: AppFinanceStyle.textDefault),
              ),
            ),
          ),
        _buildProfitOverview(),
        const SizedBox(height: 28),
        _buildPositionsSection(),
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
      children: [_buildAccountPageContent()],
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncNoDropdownAccountLabel();
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          (widget.showRealtimeAppBarTitle ||
                  _appUserRole == AppUserRole.customer)
              ? '实时收益'
              : '账户收益',
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
                        style: TextStyle(color: AppFinanceStyle.textDefault),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _load, child: const Text('重试')),
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
        style: AppFinanceStyle.labelTextStyle(
          context,
        ).copyWith(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    );
  }

  /// 1. 账户盈利总览（与 Web 账户画像核心指标一致，不含机器人/交易所细节）
  Widget _buildProfitOverview() {
    final a = _selectedAccount;
    if (a == null) return const SizedBox.shrink();
    final equity = a.equityUsdt;
    final assetBal = a.cashBalance ?? a.balanceUsdt;
    final singleInst =
        _positions.isNotEmpty &&
        _positions.map((p) => p.instId).toSet().length == 1;
    final curPx = singleInst && _positions.isNotEmpty
        ? (_liveLastPx ?? _singleInstQuotePx())
        : 0.0;
    final floating = singleInst && curPx > 0
        ? _totalDynUpl(_positions, curPx)
        : a.floatingProfit;
    final rate = a.profitPercent;
    final rateColor = rate >= 0
        ? AppFinanceStyle.textProfit
        : AppFinanceStyle.textLoss;
    final titleSize =
        (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 2;

    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('账户盈利总览'),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, c) {
              final chipBal = _overviewChip(
                context,
                '余额',
                _fmt(assetBal),
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
                formatUiSignedInteger(floating),
                titleSize: titleSize,
                valueColor: floating >= 0
                    ? AppFinanceStyle.profitGreenEnd
                    : AppFinanceStyle.textLoss,
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
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: chipIni),
                      const SizedBox(width: 8),
                      Expanded(child: chipBal),
                      const SizedBox(width: 8),
                      Expanded(child: chipRate),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: chipEq),
                      const SizedBox(width: 12),
                      Expanded(child: chipFl),
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

  /// 当前持仓与每腿浮动（与 Web「账户画像」同源接口；单合约时浮动与总览「浮动盈亏」一致）。
  Widget _buildPositionsSection() {
    if (_selectedAccount == null) return const SizedBox.shrink();
    final positions = _positions;
    final singleInst =
        positions.isNotEmpty &&
        positions.map((p) => p.instId).toSet().length == 1;
    final curPx = singleInst && positions.isNotEmpty
        ? (_liveLastPx ?? _singleInstQuotePx())
        : 0.0;
    final totalFloating = singleInst && curPx > 0
        ? _totalDynUpl(positions, curPx)
        : positions.fold<double>(0, (s, p) => s + p.upl);

    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('当前持仓'),
          const SizedBox(height: 12),
          if (_positionsLoadError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _positionsLoadError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ),
          if (positions.isEmpty && _positionsLoadError == null)
            Text('暂无持仓', style: AppFinanceStyle.labelTextStyle(context)),
          if (positions.isNotEmpty) ...[
            Text(
              '浮动盈亏：${formatUiSignedInteger(totalFloating)}',
              style: AppFinanceStyle.valueTextStyle(context, fontSize: 18)
                  .copyWith(
                    color: totalFloating >= 0
                        ? AppFinanceStyle.textProfit
                        : AppFinanceStyle.textLoss,
                  ),
            ),
            const SizedBox(height: 12),
            ...positions.map((p) {
              final side = p.posSide == 'long' ? '多' : '空';
              final lineUpl = singleInst && curPx > 0
                  ? _dynUplFor(p, curPx)
                  : p.upl;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        '· $side · ${formatUiInteger(p.pos)}',
                        style: AppFinanceStyle.labelTextStyle(
                          context,
                        ).copyWith(fontSize: 12),
                      ),
                    ),
                    Text(
                      formatUiSignedInteger(lineUpl),
                      style:
                          AppFinanceStyle.valueTextStyle(
                            context,
                            fontSize: 16,
                          ).copyWith(
                            color: lineUpl >= 0
                                ? AppFinanceStyle.profitGreenEnd
                                : AppFinanceStyle.textLoss,
                            fontSize: 12,
                          ),
                    ),
                  ],
                ),
              );
            }),
          ],
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
    final plotH =
        calendarGridPixelHeightForCap(calCap, compact: false) *
        _kLineBarHeightFactor;
    final calendarGridH = _calendarGridMaxHeightDoubled(plotH);

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
            description: '',
            valueAt: (s) => s.currentBalance,
            emptyMessage: '暂无历史快照，无法统计月度现金余额',
            showMonthNavigator: false,
            focusedMonth: month,
            onFocusedMonthChanged: setCashMonth,
            gridMaxHeight: calendarGridH,
            dailyCloseCounts: _cashCalendarCloseCounts,
          ),
        ),
        const SizedBox(height: 20),
        _partHeading('现金曲线'),
        _glassCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
            description: '',
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
    final plotH =
        calendarGridPixelHeightForCap(calCap, compact: false) *
        _kLineBarHeightFactor;
    final calendarGridH = _calendarGridMaxHeightDoubled(plotH);

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
            description: '',
            valueAt: (s) => s.equityUsdt,
            emptyMessage: '暂无历史快照，无法统计月度权益',
            showMonthNavigator: false,
            focusedMonth: month,
            onFocusedMonthChanged: setEquityMonth,
            gridMaxHeight: calendarGridH,
            dailyCloseCounts: _equityCalendarCloseCounts,
          ),
        ),
        const SizedBox(height: 20),
        _partHeading('权益曲线'),
        _glassCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
            description: '',
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
    final labelStyle = AppFinanceStyle.labelTextStyle(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label, style: labelStyle),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            value,
            style: numberStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.start,
          ),
        ),
      ],
    );
  }
}
