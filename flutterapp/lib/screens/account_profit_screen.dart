import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../constants/poll_intervals.dart';
import '../api/models.dart';
import '../auth/app_user_role.dart';
import '../debug_ingest_log.dart';
import '../secure/prefs.dart';
import '../utils/network_error_message.dart';
import '../services/okx_public_ticker_ws.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import '../widgets/equity_cash_percent_line_chart.dart';
import '../widgets/month_end_profit_panel.dart';
import '../widgets/account_detail_loading_overlay.dart';
import '../widgets/water_background.dart';

/// [_AccountProfitScreenState] 内现金三块图表共享的布局参数（按次 build 计算，供 Sliver 懒构建复用）。
class _AccountProfitCashLayout {
  _AccountProfitCashLayout({
    required this.snap,
    required this.month,
    required this.setCashMonth,
    required this.plotH,
    required this.calendarGridH,
  });

  final List<BotProfitSnapshot> snap;
  final DateTime month;
  final void Function(DateTime) setCashMonth;
  final double plotH;
  final double calendarGridH;
}

/// APK「账户收益」（客户视图）：账户选择 → 账户盈利总览 → 当前持仓 → 现金（日历 / 曲线 / 每日）。
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

class _AccountProfitScreenState extends State<AccountProfitScreen>
    with WidgetsBindingObserver {
  final _prefs = SecurePrefs();
  List<AccountProfit> _accounts = [];
  List<UnifiedTradingBot> _bots = [];
  String? _selectedBotId;
  List<BotProfitSnapshot> _snapshots = [];
  bool _loading = true;
  /// 阶段二：收益/历史/持仓等与首屏账户列表并行请求期间为 true。
  bool _detailLoading = false;
  /// 为 true 时表示用户切换了下拉账户，遮罩文案与会话侧重提示切换。
  bool _switchingAccount = false;
  String? _error;
  Timer? _autoRefreshTimer;
  Timer? _historyRefreshTimer;
  OkxPublicTickerWs? _tickerWs;
  StreamSubscription<double>? _tickerSub;
  double? _liveLastPx;
  String? _tickerSubscribedInstId;
  List<OkxPosition> _positions = [];
  String? _positionsLoadError;
  static const String _defaultBotId = 'simpleserver';
  /// 在 147 基础上再缩小 30%（≈103），与日历/柱卡整体高度一致下调。
  static const double _kUnifiedChartBandHeight = 147.0 * 0.7;
  static const double _kLineBarHeightFactor = 0.7;

  /// 移动端日历 [gridMaxHeight]：与 [MonthEndValueCalendarPanel.compact] 行距一致，
  /// 单元格高度按 2 倍放大（原 4 倍）并整体封顶，降低首屏绘制面积。
  double _calendarGridBudgetMobile(
    double lineBarPlotHeight, {
    required bool compact,
  }) {
    const headerH = 22.0;
    const rows = 6.0;
    final rowSpacing = compact ? 1.5 : 3.0;
    final overhead = headerH + rowSpacing + rows * rowSpacing;
    final baseCell = ((lineBarPlotHeight - overhead) / rows).clamp(22.0, 40.0);
    final tallCell = baseCell * 2;
    final raw = headerH + rowSpacing + rows * (tallCell + rowSpacing);
    // 在既有缩放上再缩小 30%，与 [_kUnifiedChartBandHeight] 同步收紧。
    return ((raw * 0.7).clamp(112.0, 168.0) * 0.7).clamp(70.0, 118.0);
  }

  DateTime? _cashMetricsMonth;
  final TextEditingController _noDropdownAccountController =
      TextEditingController();

  /// 与 `_load` 同步，用于客户视图下禁用账户下拉、仅只读展示已绑定账户。
  AppUserRole _appUserRole = AppUserRole.trader;

  /// 切换账户时递增，用于丢弃过期的异步结果与日历同步。
  int _accountSwitchGeneration = 0;

  /// 全量 [_load] 并发时递增，避免多次触发时阶段二互相覆盖 [_detailLoading]。
  int _loadGeneration = 0;

  /// 立即断开 OKX 公共 ticker WS（切换账户须先于新请求调用，避免旧连接推送干扰）。
  void _disconnectOkxPublicTicker() {
    _tickerSub?.cancel();
    _tickerSub = null;
    _tickerWs?.dispose();
    _tickerWs = null;
    _tickerSubscribedInstId = null;
    _liveLastPx = null;
  }

  /// 定时轮询：账户汇总 + 持仓（与 Web 切片一致）；不打 profit-history，减轻流量与 OKX。
  Future<void> _refreshLiveSlice() async {
    if (!mounted || _loading || _detailLoading) return;
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
        api.getTradingbotPositions(botId),
      ]);
      if (!mounted || g != _accountSwitchGeneration) return;
      final profitResp = batch[0] as AccountProfitResponse;
      final posResp = batch[1] as OkxPositionsResponse;
      setState(() {
        _accounts = profitResp.accounts ?? [];
        _positions = posResp.positions;
        _positionsLoadError = posResp.positionsError;
      });
      _syncOkxTickerSubscription();
    } catch (_) {
      // 后台轮询失败不打扰主流程
    }
  }

  /// 低频刷新收益曲线快照（仅 DB，不经 OKX）；下拉 [_load] 仍会全量拉取。
  Future<void> _refreshProfitHistoryOnly() async {
    if (!mounted || _loading || _detailLoading) return;
    final list = _bots.isNotEmpty ? _bots : widget.sharedBots;
    final isCustomer =
        (await _prefs.getAppUserRole()) == AppUserRole.customer;
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
      final historyResp = await api.getBotProfitHistory(botId);
      if (!mounted || g != _accountSwitchGeneration) return;
      setState(() {
        _snapshots = historyResp.snapshots;
        _cashMetricsMonth = null;
      });
    } catch (_) {
      // 后台轮询失败不打扰主流程
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final g = ++_loadGeneration;
    _accountSwitchGeneration++;
    setState(() {
      _loading = true;
      _detailLoading = false;
      _switchingAccount = false;
      _error = null;
    });
    try {
      final role = await _prefs.getAppUserRole();
      // #region agent log
      unawaited(
        debugIngestLog(
          location: 'account_profit_screen.dart:_load',
          message: 'load_start',
          hypothesisId: 'H2',
          data: <String, Object?>{
            'loadGeneration': g,
            'loadingBefore': _loading,
            'detailLoadingBefore': _detailLoading,
            'role': role.apiValue,
            'sharedBotsCount': widget.sharedBots.length,
            'initialBotId': widget.initialBotId,
          },
        ),
      );
      // #endregion
      if (!mounted || g != _loadGeneration) return;
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
      if (!mounted || g != _loadGeneration) return;
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

      if (!mounted || g != _loadGeneration) return;
      // 阶段一：一有账户列表就结束全屏 loading；客户仅只读展示绑定账户，不显示下拉
      setState(() {
        _bots = bots;
        _selectedBotId = botId;
        _loading = false;
        _detailLoading = true;
      });
      // #region agent log
      unawaited(
        debugIngestLog(
          location: 'account_profit_screen.dart:_load',
          message: 'phase1_bots_ready',
          hypothesisId: 'H3',
          data: <String, Object?>{
            'botsCount': bots.length,
            'selectedBotId': botId,
            'isCustomer': isCustomer,
            'fromSharedBots': widget.sharedBots.isNotEmpty,
          },
        ),
      );
      // #endregion

      // 阶段二：收益、历史、持仓并行（缩短首屏等待）
      try {
        if (botId != null && botId.isNotEmpty) {
          final out = await Future.wait([
            api.getAccountProfit(),
            api.getBotProfitHistory(botId),
            api.getTradingbotPositions(botId),
          ]);
          if (!mounted || g != _loadGeneration) return;
          final profitResp = out[0] as AccountProfitResponse;
          final historyResp = out[1] as BotProfitHistoryResponse;
          final posResp = out[2] as OkxPositionsResponse;
          setState(() {
            _accounts = profitResp.accounts ?? [];
            _snapshots = historyResp.snapshots;
            _positions = posResp.positions;
            _positionsLoadError = posResp.positionsError;
            _cashMetricsMonth = null;
            _detailLoading = false;
            _switchingAccount = false;
          });
          // #region agent log
          unawaited(
            debugIngestLog(
              location: 'account_profit_screen.dart:_load',
              message: 'phase2_success',
              hypothesisId: 'H2',
              data: <String, Object?>{
                'accountsCount': _accounts.length,
                'snapshotsCount': _snapshots.length,
                'positionsCount': _positions.length,
                'selectedBotId': _selectedBotId,
                'hasSelectedAccount': _selectedAccount != null,
              },
            ),
          );
          // #endregion
          _syncOkxTickerSubscription();
        } else {
          final profitResp = await api.getAccountProfit();
          if (!mounted || g != _loadGeneration) return;
          setState(() {
            _accounts = profitResp.accounts ?? [];
            _snapshots = const [];
            _cashMetricsMonth = null;
            _detailLoading = false;
            _switchingAccount = false;
          });
          // #region agent log
          unawaited(
            debugIngestLog(
              location: 'account_profit_screen.dart:_load',
              message: 'phase2_success_no_bot',
              hypothesisId: 'H3',
              data: <String, Object?>{
                'accountsCount': _accounts.length,
                'isCustomer': isCustomer,
                'selectedBotId': _selectedBotId,
              },
            ),
          );
          // #endregion
        }
      } catch (e) {
        if (!mounted || g != _loadGeneration) return;
        // #region agent log
        unawaited(
          debugIngestLog(
            location: 'account_profit_screen.dart:_load',
            message: 'phase2_error',
            hypothesisId: 'H5',
            data: <String, Object?>{
              'errorType': e.runtimeType.toString(),
              'error': e.toString(),
              'selectedBotId': _selectedBotId,
              'detailLoadingBeforeSetState': _detailLoading,
            },
          ),
        );
        // #endregion
        if (mounted) {
          setState(() {
            _error = '收益/历史/持仓加载失败：${friendlyNetworkError(e)}';
            _detailLoading = false;
            _switchingAccount = false;
          });
        }
      }
    } catch (e) {
      if (!mounted || g != _loadGeneration) return;
      // #region agent log
      unawaited(
        debugIngestLog(
          location: 'account_profit_screen.dart:_load',
          message: 'load_outer_error',
          hypothesisId: 'H5',
          data: <String, Object?>{
            'errorType': e.runtimeType.toString(),
            'error': e.toString(),
          },
        ),
      );
      // #endregion
      if (!mounted) return;
      setState(() {
        _error = friendlyNetworkError(e);
        _loading = false;
        _detailLoading = false;
        _switchingAccount = false;
      });
    }
  }

  Future<void> _loadForBot(String botId) async {
    _loadGeneration++;
    _disconnectOkxPublicTicker();
    final g = ++_accountSwitchGeneration;
    setState(() {
      _selectedBotId = botId;
      _positions = [];
      _positionsLoadError = null;
      _error = null;
      _detailLoading = true;
      _switchingAccount = true;
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
        _cashMetricsMonth = null;
      });

      final phase2 = await api.getTradingbotPositions(botId);
      if (!mounted || g != _accountSwitchGeneration) return;
      setState(() {
        _positions = phase2.positions;
        _positionsLoadError = phase2.positionsError;
        _detailLoading = false;
        _switchingAccount = false;
      });
      _syncOkxTickerSubscription();
    } catch (e) {
      if (mounted && g == _accountSwitchGeneration) {
        setState(() {
          _error = '切换账户后加载失败：${friendlyNetworkError(e)}';
          _detailLoading = false;
          _switchingAccount = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    unawaited(_syncAutoRefreshTimers());
  }

  Future<void> _syncAutoRefreshTimers() async {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    _historyRefreshTimer?.cancel();
    _historyRefreshTimer = null;
    if (!widget.periodicRefreshActive) return;
    final role = await _prefs.getAppUserRole();
    if (!mounted || !widget.periodicRefreshActive) return;
    final isCustomer = role == AppUserRole.customer;
    final livePoll = isCustomer
        ? PollIntervals.accountProfitCustomerLivePoll
        : PollIntervals.mediumPoll;
    final historyPoll = isCustomer
        ? PollIntervals.accountProfitCustomerHistoryPoll
        : PollIntervals.slowPoll;
    _autoRefreshTimer = Timer.periodic(
      livePoll,
      (_) => unawaited(_refreshLiveSlice()),
    );
    _historyRefreshTimer = Timer.periodic(
      historyPoll,
      (_) => unawaited(_refreshProfitHistoryOnly()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _autoRefreshTimer?.cancel();
      _autoRefreshTimer = null;
      _historyRefreshTimer?.cancel();
      _historyRefreshTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_syncAutoRefreshTimers());
    }
  }

  @override
  void didUpdateWidget(covariant AccountProfitScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.periodicRefreshActive != widget.periodicRefreshActive) {
      unawaited(_syncAutoRefreshTimers());
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
    WidgetsBinding.instance.removeObserver(this);
    _noDropdownAccountController.dispose();
    _disconnectOkxPublicTicker();
    _autoRefreshTimer?.cancel();
    _historyRefreshTimer?.cancel();
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

  DateTime _cashMonthFor(List<BotProfitSnapshot> snap) {
    final seed = _cashMetricsMonth ?? focusedMonthFromProfitSnapshots(snap);
    return clampMonthToSnapshots(snap, seed);
  }

  /// 「当前账户」展示：优先账户名称（account_name / tradingbot_name），避免仅显示交易所简称（如 OKX）
  String _displayAccountTitle(AccountProfit a) {
    final fromApi = a.accountName?.trim();
    if (fromApi != null && fromApi.isNotEmpty) return fromApi;
    final id = a.botId;
    if (id.isNotEmpty) {
      for (final b in _effectiveBots) {
        if (b.tradingbotId == id) {
          final tn = b.tradingbotName?.trim();
          if (tn != null && tn.isNotEmpty) return tn;
          break;
        }
      }
    }
    if (id.isNotEmpty) return id;
    final ex = a.exchangeAccount.trim();
    return ex.isNotEmpty ? ex : '';
  }

  void _syncNoDropdownAccountLabel() {
    final isCustomer = _appUserRole == AppUserRole.customer;
    // 非客户且存在 bot 列表时用下拉框，此处不维护只读文案
    if (!isCustomer && _effectiveBots.isNotEmpty) return;

    final a = _selectedAccount;
    String text;
    if (a != null) {
      text = _displayAccountTitle(a);
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

  Widget _buildBotSelector({bool forAppBar = false}) {
    final list = _effectiveBots;
    if (list.isEmpty) return const SizedBox.shrink();
    // 交易员/管理员：无论 1 个或多个交易账户都使用 DropdownButton；客户仅用只读展示
    final mq = MediaQuery.of(context).size.width;
    final card = _glassCard(
      Padding(
        padding: EdgeInsets.symmetric(
          horizontal: forAppBar ? 6 : 4,
          vertical: forAppBar ? 2 : 4,
        ),
        child: Builder(
          builder: (context) {
            final heading =
                AppFinanceStyle.accountProfitOverviewHeadingStyle(context);
            final menuStyle = forAppBar
                ? heading.copyWith(fontSize: (heading.fontSize ?? 16) - 1)
                : heading;
            return DropdownButton<String>(
              value: _selectedBotId ?? list.first.tradingbotId,
              isExpanded: true,
              padding: EdgeInsets.zero,
              isDense: forAppBar,
              iconSize: forAppBar ? 22 : 28,
              itemHeight: forAppBar ? 44 : 52,
              underline: const SizedBox.shrink(),
              icon: Icon(
                Icons.arrow_drop_down,
                color: menuStyle.color,
                size: forAppBar ? 22 : 28,
              ),
              dropdownColor: AppFinanceStyle.cardBackground.withValues(
                alpha: 0.98,
              ),
              style: menuStyle,
              items: list
                  .map(
                    (b) => DropdownMenuItem<String>(
                      value: b.tradingbotId,
                      child: Text(
                        b.tradingbotName ?? b.tradingbotId,
                        style: menuStyle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) _loadForBot(v);
              },
            );
          },
        ),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: forAppBar ? 8 : 12,
        vertical: forAppBar ? 4 : 8,
      ),
    );
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (mq * (forAppBar ? 0.52 : 0.45)).clamp(
            forAppBar ? 140.0 : 160.0,
            forAppBar ? 300.0 : 280.0,
          ),
          minHeight: forAppBar ? 40 : kMinInteractiveDimension,
        ),
        child: card,
      ),
    );
  }

  Widget _glassCard(Widget child, {EdgeInsetsGeometry? padding}) {
    return FinanceCard(
      padding: padding ?? const EdgeInsets.all(20),
      child: child,
    );
  }

  /// 首屏与轻量区块：错误、账户选择、空态、总览、持仓（不内含现金图表，供 Sliver 首项懒加载边界）。
  Widget _buildAccountScrollHead() {
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
        // 客户：只读账户条。交易员/管理员仅在「无下拉数据源」时用只读条（有 _effectiveBots 时只用 AppBar 下拉）。
        if ((_appUserRole == AppUserRole.customer &&
                _effectiveBots.isNotEmpty) ||
            (_selectedAccount != null &&
                (_appUserRole == AppUserRole.customer ||
                    _effectiveBots.isEmpty))) ...[
          _buildNoDropdownAccountField(),
          const SizedBox(height: 20),
        ],
        if (_accounts.isEmpty && _error == null && !_detailLoading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _appUserRole == AppUserRole.customer
                      ? '请让管理员在用户管理中核对：绑定的 account_id 须与 Account_List 里的 account_id 完全一致（与 OKX 密钥 JSON 里的 name 无关）。执行 baasapi 下 python3 seed_team_users.py 可同步团队客户绑定。'
                      : '暂无账户数据，请确认后端 accounts 已配置交易账户',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color.fromARGB(255, 125, 18, 31),
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ),
        _buildProfitOverview(),
        const SizedBox(height: 28),
        _buildPositionsSection(),
      ],
    );
  }

  _AccountProfitCashLayout? _layoutCashPanelsIfNeeded() {
    if (_selectedAccount == null) return null;
    final snap = _snapshots;
    final month = _cashMonthFor(snap);
    void setCashMonth(DateTime d) {
      setState(() => _cashMetricsMonth = clampMonthToSnapshots(snap, d));
    }
    const calCompact = true;
    final calCap = _kUnifiedChartBandHeight;
    final plotH =
        calendarGridPixelHeightForCap(calCap, compact: calCompact) *
        _kLineBarHeightFactor;
    final calendarGridH = _calendarGridBudgetMobile(
      plotH,
      compact: calCompact,
    );
    return _AccountProfitCashLayout(
      snap: snap,
      month: month,
      setCashMonth: setCashMonth,
      plotH: plotH,
      calendarGridH: calendarGridH,
    );
  }

  Widget _buildCashCalendarPanel(_AccountProfitCashLayout L) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _partHeading('现金日历视图'),
        if (L.snap.isNotEmpty) ...[
          _buildMetricsMonthNav(
            snapshots: L.snap,
            month: L.month,
            onMonthChanged: L.setCashMonth,
          ),
          const SizedBox(height: 12),
        ],
        _glassCard(
          MonthEndValueCalendarPanel(
            snapshots: L.snap,
            title: '',
            description: '',
            valueAt: (s) => s.cashBalance ?? s.currentBalance,
            emptyMessage: '暂无历史快照，无法统计月度现金余额',
            showMonthNavigator: false,
            focusedMonth: L.month,
            onFocusedMonthChanged: L.setCashMonth,
            gridMaxHeight: L.calendarGridH,
            compact: true,
            hideZeroDailyValues: true,
          ),
          // 原 6 → 约缩小 70% 内边距，日历更贴近卡片边缘
          padding: const EdgeInsets.all(2),
        ),
      ],
    );
  }

  Widget _buildCashLinePanel(_AccountProfitCashLayout L) {
    final a = _selectedAccount;
    final cashMonthOpen = a == null
        ? null
        : (a.monthInitialBalance ?? a.cashBalance ?? a.initialBalance);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _partHeading('现金曲线'),
        _glassCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: L.plotH,
                child: RepaintBoundary(
                  child: SnapshotPercentLineChart(
                    snapshots: L.snap,
                    series: SnapshotReturnSeries.cash,
                    compact: true,
                    focusedMonth: L.month,
                    monthOpenLevelHint: cashMonthOpen,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCashDailyPanel(_AccountProfitCashLayout L) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _partHeading('每日现金'),
        _glassCard(
          MonthEndValueBarPanel(
            snapshots: L.snap,
            title: '',
            description: '',
            valueAt: (s) => s.cashBalance ?? s.currentBalance,
            emptyMessage: '暂无历史快照，无法统计月度现金余额',
            showMonthNavigator: false,
            selectedEndMonth: L.month,
            onSelectedEndMonthChanged: L.setCashMonth,
            barChartHeight: L.plotH,
            maxBars: 8,
            useDailyBarsForEndMonth: true,
            compact: true,
            dailyBarsLeftAxisInterval: 100,
          ),
        ),
      ],
    );
  }

  /// 仅可滚动主体。[RefreshIndicator] 的直接子节点必须是 Scrollable，不能是 Stack。
  Widget _buildProfitScrollView(double minHeightForPlaceholder) {
    if (_loading && _accounts.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeightForPlaceholder),
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_error != null && _accounts.isEmpty && !_detailLoading) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeightForPlaceholder),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppFinanceStyle.textDefault),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _load,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final cash = _layoutCashPanelsIfNeeded();
    final childCount = cash != null ? 4 : 1;
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                switch (index) {
                  case 0:
                    return Padding(
                      padding: EdgeInsets.only(bottom: cash != null ? 28 : 0),
                      child: _buildAccountScrollHead(),
                    );
                  case 1:
                    return cash == null
                        ? const SizedBox.shrink()
                        : _buildCashCalendarPanel(cash);
                  case 2:
                    if (cash == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: _buildCashLinePanel(cash),
                    );
                  case 3:
                    if (cash == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: _buildCashDailyPanel(cash),
                    );
                  default:
                    return const SizedBox.shrink();
                }
              },
              childCount: childCount,
            ),
          ),
        ),
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
        actions: [
          if (_appUserRole != AppUserRole.customer && _effectiveBots.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildBotSelector(forAppBar: true),
              ),
            ),
        ],
        backgroundColor: AppFinanceStyle.backgroundDark,
        foregroundColor: AppFinanceStyle.valueColor,
        surfaceTintColor: Colors.transparent,
      ),
      body: WaterBackground(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final rawH = constraints.maxHeight;
            final minH = (rawH.isFinite && rawH > 0)
                ? rawH
                : MediaQuery.sizeOf(context).height;
            return Stack(
              children: [
                Positioned.fill(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: _buildProfitScrollView(minH),
                  ),
                ),
                AccountDetailLoadingOverlay(
                  visible: _detailLoading,
                  message: _switchingAccount
                      ? '正在切换账户…'
                      : '正在加载收益数据…',
                  subtitle: _switchingAccount
                      ? '正在拉取该账户的收益、持仓与曲线'
                      : null,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: AppFinanceStyle.accountProfitOverviewHeadingStyle(context),
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

  /// 1. 账户盈利总览（与 [AccountsList] 顶栏一致：三列标签上、数值下、列内居中）
  Widget _buildProfitOverview() {
    final a = _selectedAccount;
    if (a == null) return const SizedBox.shrink();
    final rate = a.profitPercent;
    final rateColor = rate >= 0
        ? AppFinanceStyle.textProfit
        : AppFinanceStyle.textLoss;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('账户盈利总览'),
        const SizedBox(height: 12),
        FinanceCard(
          padding: AppFinanceStyle.mobileSummaryStripPadding,
          child: Builder(
            builder: (context) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: AppFinanceStyle.mobileSummaryStackCell(
                        context,
                        label: '月初',
                        value: _fmt(a.initialBalance),
                        valueColor: AppFinanceStyle.valueColor,
                      ),
                    ),
                    Expanded(
                      child: AppFinanceStyle.mobileSummaryStackCell(
                        context,
                        label: '资产余额',
                        value: _fmt(a.equityUsdt),
                        valueColor: AppFinanceStyle.valueColor,
                      ),
                    ),
                    Expanded(
                      child: AppFinanceStyle.mobileSummaryStackCell(
                        context,
                        label: '盈利率',
                        value: _fmtPct(rate),
                        valueColor: rateColor,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
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
                        ).copyWith(fontSize: 16),
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

}
