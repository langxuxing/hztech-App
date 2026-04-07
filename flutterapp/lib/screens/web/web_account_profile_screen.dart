import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../services/okx_public_ticker_ws.dart';
import '../../theme/finance_style.dart';
import '../../utils/number_display_format.dart';
import '../../widgets/equity_cash_percent_line_chart.dart';
import '../../widgets/month_end_profit_panel.dart';
import '../../widgets/account_detail_loading_overlay.dart';
import '../../widgets/water_background.dart';

/// OKX 部分合约标价极小，[formatUiInteger] 四舍五入会落成 0；展示时乘以 1e9（内部盈亏比例仍用原价）。
const double _kOkxContractPxUiScale = 1e9;

String _fmtOkxContractPxForUi(double v) {
  if (!v.isFinite) return '—';
  return formatUiInteger(v * _kOkxContractPxUiScale);
}

/// Web「账户画像」：顶栏账户选择 → 账户详情 → 持仓|赛季（宽屏 50/50）→ 现金/权益各一行三列（折线|柱|日历）。
///
/// 视口 ≥[_kLayoutWideBp] 为上述栅格；更窄同序纵向堆叠。超宽内容限制在 [_maxContentWidth] 内居中。
/// [embedInShell] 缺省 true（侧栏 Tab 无本页 AppBar）；独立路由请用 [WebAccountProfitScreen] 或传入 false。
class WebAccountProfileScreen extends StatefulWidget {
  const WebAccountProfileScreen({
    super.key,
    this.sharedBots = const [],
    this.initialBotId,
    this.embedInShell = true,
    this.periodicRefreshActive = true,
  });

  /// 与仪表盘、策略页同源的交易账户列表；可为空则本页自拉。
  final List<UnifiedTradingBot> sharedBots;

  /// 进入时默认选中的交易账户 ID。
  final String? initialBotId;

  /// 嵌入 [WebMainShell] 侧栏时为 true（缺省）；独立 push 路由时为 false 以显示本页 AppBar。
  final bool embedInShell;

  /// 为 false 时不启动定时刷新（如 [IndexedStack] 非当前 Tab）。
  final bool periodicRefreshActive;

  @override
  State<WebAccountProfileScreen> createState() =>
      _WebAccountProfileScreenState();
}

class _WebAccountProfileScreenState extends State<WebAccountProfileScreen> {
  static const double _maxContentWidth = 1680;
  final _prefs = SecurePrefs();
  List<AccountProfit> _accounts = [];
  List<UnifiedTradingBot> _bots = [];
  String? _selectedBotId;
  List<BotProfitSnapshot> _snapshots = [];
  List<OkxPosition> _positions = [];
  List<BotSeason> _seasons = [];
  bool _loading = true;
  /// 阶段二：收益/历史/持仓/赛季等与账户列表并行请求期间为 true。
  bool _detailLoading = false;
  /// 用户切换账户时为 true，用于遮罩主副标题区分「切换」与「首屏加载」。
  bool _switchingAccount = false;
  String? _error;
  String? _positionsLoadError;
  Map<String, dynamic>? _positionsOkxDebug;
  Timer? _autoRefreshTimer;
  OkxPublicTickerWs? _tickerWs;
  StreamSubscription<double>? _tickerSub;
  double? _liveLastPx;
  String? _tickerSubscribedInstId;
  static const String _defaultBotId = 'simpleserver';
  static const double _kLayoutWideBp = 960;

  /// 权益/现金宽屏三列整行高度（无内层滚动）。
  /// 较 520 略增，为 fl_chart 轴标签 + 标题留足余量，避免「每日现金」等底部溢出。
  static const double _kTripleRowHeight = 544;

  /// 宽屏「当前持仓 | 赛季盈利」行高（较原三列行高减少 30%）。
  static const double _kPositionsSeasonRowHeight = _kTripleRowHeight * 0.7;
  static const double _kTripleGutter = 12;

  /// 宽屏权益/现金「日历 | 折线+柱」整行较 [_kTripleRowHeight] 加高 10%，日历网格更大。
  static double get _kTripleMetricsRowHeight => _kTripleRowHeight * 0.77;

  /// 「权益日历」「现金日历」标题与下方内容（含星期行）的额外间距。
  static const double _kProfileCalendarTitleExtraGap = 22;

  /// 窄屏与宽屏单列内折线/柱/日历图表区统一高度。
  static const double _kUnifiedChartBandHeight = 420;
  static const double _kLineBarHeightFactor = 0.7;

  DateTime? _equityMetricsMonth;
  DateTime? _cashMetricsMonth;

  /// 与 [_equityMetricsMonth] 对应月的 daily-realized-pnl（含 account_daily_performance 合并字段）
  List<DailyRealizedPnlDayRow> _equityPerfDays = const [];

  /// 与 [_cashMetricsMonth] 对应月
  List<DailyRealizedPnlDayRow> _cashPerfDays = const [];
  final TextEditingController _noDropdownAccountController =
      TextEditingController();

  /// 切换账户时递增，用于丢弃过期的异步结果与日历同步。
  int _accountSwitchGeneration = 0;

  /// 立即断开 OKX 公共 ticker WS（切换账户须先于新请求调用）。
  void _disconnectOkxPublicTicker() {
    _tickerSub?.cancel();
    _tickerSub = null;
    _tickerWs?.dispose();
    _tickerWs = null;
    _tickerSubscribedInstId = null;
    _liveLastPx = null;
  }

  String? get _trimmedInitialBotId {
    final s = widget.initialBotId?.trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }

  /// 若 [initialBotId] 不在列表中则前置占位项，保证下拉框 value 合法且与仪表盘点入的账户一致。
  List<UnifiedTradingBot> _mergeInitialPlaceholder(
    List<UnifiedTradingBot> bots,
  ) {
    final initial = _trimmedInitialBotId;
    if (initial == null) return List<UnifiedTradingBot>.from(bots);
    if (bots.any((b) => b.tradingbotId == initial)) {
      return List<UnifiedTradingBot>.from(bots);
    }
    return [
      UnifiedTradingBot(
        tradingbotId: initial,
        status: '',
        canControl: false,
        isTest: false,
      ),
      ...bots,
    ];
  }

  String _pickBotIdForLoad(List<UnifiedTradingBot> bots) {
    final initial = _trimmedInitialBotId;
    if (initial != null) return initial;
    if (bots.isNotEmpty) return bots.first.tradingbotId;
    return _defaultBotId;
  }

  /// 保持当前选中账户，拉取最新收益、曲线、持仓与赛季（用于定时刷新与下拉切换后的全量刷新）
  Future<void> _refreshLatestData() async {
    if (!mounted || _loading || _detailLoading) return;
    final list = _bots.isNotEmpty ? _bots : widget.sharedBots;
    final botId =
        _selectedBotId ??
        (list.isNotEmpty ? list.first.tradingbotId : null) ??
        _defaultBotId;
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
        api.getTradingbotSeasons(botId, limit: 50),
      ]);
      if (!mounted || g != _accountSwitchGeneration) return;
      final profitResp = batch[0] as AccountProfitResponse;
      final historyResp = batch[1] as BotProfitHistoryResponse;
      final positionsResp = batch[2] as OkxPositionsResponse;
      final seasonsResp = batch[3] as TradingbotSeasonsResponse;
      setState(() {
        _accounts = profitResp.accounts ?? [];
        _snapshots = historyResp.snapshots;
        _positions = positionsResp.positions;
        _positionsLoadError = positionsResp.positionsError;
        _positionsOkxDebug = positionsResp.okxDebug;
        _seasons = seasonsResp.seasons;
        _equityMetricsMonth = null;
        _cashMetricsMonth = null;
        _equityPerfDays = const [];
        _cashPerfDays = const [];
      });
      unawaited(_syncDailyPerformanceForCharts());
      _syncOkxTickerSubscription();
    } catch (_) {
      // 后台轮询失败不打扰主流程
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _detailLoading = false;
      _switchingAccount = false;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);

      // 优先 MainScreen 下发的列表；否则本页拉取（与账户管理同源）
      List<UnifiedTradingBot> bots = _mergeInitialPlaceholder(
        List.from(widget.sharedBots),
      );
      if (bots.isEmpty) {
        final botsResp = await api.getTradingBots();
        bots = _mergeInitialPlaceholder(botsResp.botList);
      }
      final botId = _pickBotIdForLoad(bots);

      if (!mounted) return;
      // 阶段一：一有账户列表就结束全屏 loading，下拉框可立即显示
      setState(() {
        _bots = bots;
        _selectedBotId = botId;
        _loading = false;
        _detailLoading = true;
      });

      // 阶段二：收益、历史、持仓、赛季并行（缩短首屏等待）
      try {
        final batch = await Future.wait([
          api.getAccountProfit(),
          api.getBotProfitHistory(botId),
          api.getTradingbotPositions(botId),
          api.getTradingbotSeasons(botId, limit: 50),
        ]);
        if (!mounted) return;
        final profitResp = batch[0] as AccountProfitResponse;
        final historyResp = batch[1] as BotProfitHistoryResponse;
        final positionsResp = batch[2] as OkxPositionsResponse;
        final seasonsResp = batch[3] as TradingbotSeasonsResponse;
        setState(() {
          _accounts = profitResp.accounts ?? [];
          _snapshots = historyResp.snapshots;
          _positions = positionsResp.positions;
          _positionsLoadError = positionsResp.positionsError;
          _positionsOkxDebug = positionsResp.okxDebug;
          _seasons = seasonsResp.seasons;
          _equityMetricsMonth = null;
          _cashMetricsMonth = null;
          _equityPerfDays = const [];
          _cashPerfDays = const [];
          _detailLoading = false;
          _switchingAccount = false;
        });
        unawaited(_syncDailyPerformanceForCharts());
        _syncOkxTickerSubscription();
      } catch (e) {
        if (mounted) {
          setState(() {
            _error = '收益/历史/持仓/赛季加载失败: $e';
            _detailLoading = false;
            _switchingAccount = false;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _detailLoading = false;
        _switchingAccount = false;
      });
    }
  }

  Future<void> _loadForBot(String botId) async {
    _disconnectOkxPublicTicker();
    final g = ++_accountSwitchGeneration;
    setState(() {
      _selectedBotId = botId;
      _positions = [];
      _seasons = [];
      _positionsLoadError = null;
      _positionsOkxDebug = null;
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
        _equityMetricsMonth = null;
        _cashMetricsMonth = null;
      });
      unawaited(_syncDailyPerformanceForCharts());

      final phase2 = await Future.wait([
        api.getTradingbotPositions(botId),
        api.getTradingbotSeasons(botId, limit: 50),
      ]);
      if (!mounted || g != _accountSwitchGeneration) return;
      final positionsResp = phase2[0] as OkxPositionsResponse;
      final seasonsResp = phase2[1] as TradingbotSeasonsResponse;
      setState(() {
        _positions = positionsResp.positions;
        _positionsLoadError = positionsResp.positionsError;
        _positionsOkxDebug = positionsResp.okxDebug;
        _seasons = seasonsResp.seasons;
        _detailLoading = false;
        _switchingAccount = false;
      });
      _syncOkxTickerSubscription();
    } catch (e) {
      if (mounted && g == _accountSwitchGeneration) {
        setState(() {
          _error = '切换账户后加载失败: $e';
          _detailLoading = false;
          _switchingAccount = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // 若父级已下发列表则先展示，再异步拉取收益等（选中项与 initialBotId 对齐，避免先闪第一个账户）
    if (widget.sharedBots.isNotEmpty) {
      _bots = _mergeInitialPlaceholder(List.from(widget.sharedBots));
      _selectedBotId = _pickBotIdForLoad(_bots);
    }
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
  void didUpdateWidget(covariant WebAccountProfileScreen oldWidget) {
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
    // MainScreen 异步加载完 bots 后下发，同步到本页；须保留 initialBotId 占位，否则会退回第一个账户
    if (widget.sharedBots.isNotEmpty &&
        widget.sharedBots.length != _bots.length) {
      _bots = _mergeInitialPlaceholder(List.from(widget.sharedBots));
      if (_selectedBotId == null ||
          !_bots.any((b) => b.tradingbotId == _selectedBotId)) {
        _selectedBotId = _pickBotIdForLoad(_bots);
      }
      setState(() {});
    }
    // 壳层从仪表盘切换 Tab 时下发 [initialBotId]；清空回 null 时不应回退当前选中项
    final oldI = oldWidget.initialBotId?.trim();
    final newI = _trimmedInitialBotId;
    if (oldI != newI &&
        newI != null &&
        newI.isNotEmpty &&
        newI != _selectedBotId) {
      unawaited(_loadForBot(newI));
    }
  }

  @override
  void dispose() {
    _noDropdownAccountController.dispose();
    _disconnectOkxPublicTicker();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  /// 仅单合约持仓时连接 OKX 公共 WS 推送现价；切换标的或清空持仓时断开。
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

  double? _weightedAvgPx(List<OkxPosition> side) {
    double num = 0, den = 0;
    for (final p in side) {
      if (p.avgPx <= 0) continue;
      final w = p.pos.abs();
      if (w <= 0) continue;
      num += p.avgPx * w;
      den += w;
    }
    return den > 0 ? num / den : null;
  }

  /// 用最新价近似未实现盈亏（OKX 返回的 upl 基于标记价，此处按 (last−avg)/(mark−avg) 比例缩放）。
  double _dynUplFor(OkxPosition p, double last) {
    final mark = p.markPx;
    final avg = p.avgPx;
    final denom = mark - avg;
    if (denom.abs() < 1e-12) return p.upl;
    return p.upl * (last - avg) / denom;
  }

  double _totalDynUpl(Iterable<OkxPosition> ps, double last) =>
      ps.fold<double>(0, (s, p) => s + _dynUplFor(p, last));

  /// 同一 instId 下多腿时，取任一条有效的 displayPrice / markPx（避免仅用 first 为 0）。
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

  Future<void> _syncDailyPerformanceForCharts() async {
    final gen = _accountSwitchGeneration;
    final list = _bots.isNotEmpty ? _bots : widget.sharedBots;
    final botId =
        _selectedBotId ??
        (list.isNotEmpty ? list.first.tradingbotId : null) ??
        _defaultBotId;
    final snap = _snapshots;
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
            _equityPerfDays = const [];
            _cashPerfDays = const [];
          });
          return;
        }
        setState(() {
          _equityPerfDays = r.days;
          _cashPerfDays = r.days;
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
          _equityPerfDays = rEq.success ? rEq.days : const [];
          _cashPerfDays = rCash.success ? rCash.days : const [];
        });
      }
    } catch (_) {
      if (!mounted || gen != _accountSwitchGeneration) return;
      setState(() {
        _equityPerfDays = const [];
        _cashPerfDays = const [];
      });
    }
  }

  double _equityPctLineDenominator() {
    final a = _selectedAccount;
    if (a == null) return 0;
    final m = a.monthOpenEquity;
    if (m != null && m > 1e-12) return m;
    return a.initialBalance;
  }

  double _cashPctLineDenominator() {
    final a = _selectedAccount;
    if (a == null) return 0;
    final m = a.monthInitialBalance;
    if (m != null && m > 1e-12) return m;
    return a.initialBalance;
  }

  /// 与移动端 AccountProfitScreen 一致：优先展示 account_name / tradingbot_name
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
    if (_effectiveBots.isNotEmpty) return;
    final a = _selectedAccount;
    final text = a == null ? '' : _displayAccountTitle(a);
    if (_noDropdownAccountController.text != text) {
      _noDropdownAccountController.text = text;
    }
  }

  /// 权益/现金区块共用：折线、柱、日历同一月份。
  Widget _buildMetricsMonthNav({
    required List<BotProfitSnapshot> snapshots,
    required DateTime month,
    required ValueChanged<DateTime> onMonthChanged,
  }) {
    if (snapshots.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
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

  /// 无机器人下拉列表时，用只读输入框展示当前账户（优先账户名称，而非 exchange 简称）。
  Widget _buildNoDropdownAccountField() {
    final a = _selectedAccount;
    if (a == null) return const SizedBox.shrink();
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
    // 无论 1 个或多个交易账户都使用 DropdownButton，交互一致
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
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Builder(
              builder: (context) {
                final heading =
                    AppFinanceStyle.accountProfitOverviewHeadingStyle(context);
                return DropdownButton<String>(
                  value: _selectedBotId ?? list.first.tradingbotId,
                  isExpanded: true,
                  padding: EdgeInsets.zero,
                  iconSize: 30,
                  itemHeight: 54,
                  underline: const SizedBox.shrink(),
                  icon: Icon(
                    Icons.arrow_drop_down,
                    color: heading.color,
                    size: 30,
                  ),
                  dropdownColor: AppFinanceStyle.cardBackground.withValues(
                    alpha: 0.98,
                  ),
                  style: heading,
                  items: list
                      .map(
                        (b) => DropdownMenuItem<String>(
                          value: b.tradingbotId,
                          child: Text(
                            b.tradingbotName ?? b.tradingbotId,
                            style: heading,
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

  Widget _buildAccountPageContent(bool wide) {
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
                '暂无账户数据，请确认后端 accounts 已配置交易账户',
                style: TextStyle(color: AppFinanceStyle.textDefault),
              ),
            ),
          ),
        _buildAccountDetails(),
        const SizedBox(height: 32),
        _buildPositionsSeasonsRow(wide),
        const SizedBox(height: 32),
        _buildCashMetricsSection(wide),
        const SizedBox(height: 32),
        _buildEquityMetricsSection(wide),
      ],
    );
  }

  Widget _buildBodyScrollable() {
    final wide = MediaQuery.sizeOf(context).width >= _kLayoutWideBp;
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
            child: _buildAccountPageContent(wide),
          ),
        ),
        AccountDetailLoadingOverlay(
          visible: _detailLoading,
          message: _switchingAccount
              ? '正在切换账户…'
              : '正在加载账户画像…',
          subtitle: _switchingAccount
              ? '正在拉取该账户的收益、持仓、赛季与曲线'
              : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncNoDropdownAccountLabel();
    final canPop = Navigator.of(context).canPop();
    final scaffold = Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: widget.embedInShell
          ? null
          : AppBar(
              leading: canPop
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).pop(),
                    )
                  : null,
              automaticallyImplyLeading: !canPop,
              title: Text(
                '账户详情',
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
    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _maxContentWidth) {
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                child: scaffold,
              ),
            );
          }
          return scaffold;
        },
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

  Widget _buildAccountDetails() {
    final a = _selectedAccount;
    if (a == null) return const SizedBox.shrink();
    final bot = _currentUnifiedBot;
    final equity = a.equityUsdt;
    final assetBal = a.cashBalance ?? a.balanceUsdt;
    // 与「当前持仓」价格轴上「总浮动盈亏」一致：单合约时用 WS 最新价 + [_totalDynUpl] 动态刷新。
    final singleInst =
        _positions.isNotEmpty &&
        _positions.map((p) => p.instId).toSet().length == 1;
    final curPx = singleInst && _positions.isNotEmpty
        ? (_liveLastPx ?? _singleInstQuotePx())
        : 0.0;
    final floating = singleInst && curPx > 0
        ? _totalDynUpl(_positions, curPx)
        : a.floatingProfit;
    final eqRate = a.profitPercent;
    final cashRate = a.cashProfitPercent;
    final cashAmt = a.cashProfitAmount;
    final eqAmt = a.profitAmount;
    TextStyle v() => AppFinanceStyle.valueTextStyle(
      context,
      fontSize: AppFinanceStyle.webSummaryValueFontSize * 0.66,
    );

    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '账户：${bot?.tradingbotName ?? bot?.tradingbotId ?? a.botId}',
            style:
                (Theme.of(context).textTheme.labelMedium ?? const TextStyle())
                    .copyWith(
                      color: AppFinanceStyle.labelColor,
                      fontSize:
                          (Theme.of(context).textTheme.titleLarge?.fontSize ??
                              22) +
                          4,
                    ),
          ),
          const SizedBox(height: 4),

          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < 520;
              final green = AppFinanceStyle.chartProfit;
              final red = AppFinanceStyle.chartLoss;
              Widget metricRow(List<Widget> cells) {
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
                        const SizedBox(
                          width: AppFinanceStyle.webSummaryWideGap,
                        ),
                      Expanded(child: cells[i]),
                    ],
                  ],
                );
              }

              final rowBalances = [
                _AccountDetailMetricCell(
                  label: '资产余额',
                  value: _fmt(assetBal),
                  valueStyle: v(),
                  trailingLabel: !narrow,
                ),
                _AccountDetailMetricCell(
                  label: '权益',
                  value: _fmt(equity),
                  valueStyle: v(),
                  trailingLabel: !narrow,
                ),
                _AccountDetailMetricCell(
                  label: '浮动盈亏',
                  value: _fmt(floating),
                  valueStyle: v().copyWith(color: floating >= 0 ? green : red),
                  trailingLabel: !narrow,
                ),
                _AccountDetailMetricCell(
                  label: '期初',
                  value: _fmt(a.initialBalance),
                  valueStyle: v(),
                  trailingLabel: !narrow,
                ),
              ];
              final rowReturns = [
                _AccountDetailMetricCell(
                  label: '现金收益',
                  value: _fmt(cashAmt),
                  valueStyle: v().copyWith(color: cashAmt >= 0 ? green : red),
                  trailingLabel: !narrow,
                ),
                _AccountDetailMetricCell(
                  label: '现金收益率',
                  value: _fmtPct(cashRate),
                  valueStyle: v().copyWith(color: cashRate >= 0 ? green : red),
                  trailingLabel: !narrow,
                ),
                _AccountDetailMetricCell(
                  label: '权益收益',
                  value: _fmt(eqAmt),
                  valueStyle: v().copyWith(color: eqAmt >= 0 ? green : red),
                  trailingLabel: !narrow,
                ),
                _AccountDetailMetricCell(
                  label: '权益收益率',
                  value: _fmtPct(eqRate),
                  valueStyle: v().copyWith(color: eqRate >= 0 ? green : red),
                  trailingLabel: !narrow,
                ),
              ];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  metricRow(rowBalances),
                  SizedBox(
                    height: narrow
                        ? AppFinanceStyle.webSummaryNarrowGap
                        : AppFinanceStyle.webSummaryWideGap,
                  ),
                  metricRow(rowReturns),
                ],
              );
            },
          ),
        ],
      ),
      padding: AppFinanceStyle.webSummaryStripPadding,
    );
  }

  Widget _buildPositionsSeasonsRow(bool wide) {
    if (wide) {
      // 必须在 ScrollView 内给出有限高度，否则内层 Column 的 Expanded（持仓/赛季列表）无法布局，
      // 宽屏下会出现整段不显示或布局异常。
      return SizedBox(
        height: _kPositionsSeasonRowHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _buildPositions(expandScroll: true)),
            SizedBox(width: _kTripleGutter),
            Expanded(child: _buildSeasons(expandScroll: true)),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPositions(expandScroll: false),
        const SizedBox(height: 24),
        _buildSeasons(expandScroll: false),
      ],
    );
  }

  Widget _tripleMetricCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(12),
  }) {
    return FinanceCard(padding: padding, child: child);
  }

  Widget _buildEquityMetricsSection(bool wide) {
    if (_selectedAccount == null) return const SizedBox.shrink();
    final snap = _snapshots;
    final month = _equityMonthFor(snap);
    final equityPctDenom = _equityPctLineDenominator();
    void setEquityMonth(DateTime d) {
      setState(() => _equityMetricsMonth = clampMonthToSnapshots(snap, d));
      unawaited(_syncDailyPerformanceForCharts());
    }

    if (!wide) {
      final calCap = _kUnifiedChartBandHeight;
      final plotH =
          calendarGridPixelHeightForCap(calCap, compact: false) *
          _kLineBarHeightFactor;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('权益信息'),
          const SizedBox(height: 8),
          _buildMetricsMonthNav(
            snapshots: snap,
            month: month,
            onMonthChanged: setEquityMonth,
          ),
          const SizedBox(height: 12),
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
                    dailyPerfDays: _equityPerfDays,
                    monthPerformanceDenom: equityPctDenom > 1e-12
                        ? equityPctDenom
                        : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _glassCard(
            MonthEndValueBarPanel(
              snapshots: snap,
              title: '每日权益',
              description: '',
              valueAt: (s) => s.equityUsdt,
              emptyMessage: '暂无日绩效或历史快照',
              showMonthNavigator: false,
              selectedEndMonth: month,
              onSelectedEndMonthChanged: setEquityMonth,
              barChartHeight: plotH,
              maxBars: 8,
              useDailyBarsForEndMonth: true,
              dailyPerformanceRows: _equityPerfDays,
              dailyPerformancePick: (r) => r.equityChange,
            ),
          ),
          const SizedBox(height: 16),
          _glassCard(
            MonthEndValueCalendarPanel(
              snapshots: snap,
              title: '权益日历',
              description: '',
              valueAt: (s) => s.equityUsdt,
              emptyMessage: '暂无日绩效或历史快照',
              showMonthNavigator: false,
              focusedMonth: month,
              onFocusedMonthChanged: setEquityMonth,
              gridMaxHeight: plotH,
              titleToBodyExtraGap: _kProfileCalendarTitleExtraGap,
              dailyPerformanceRows: _equityPerfDays,
              dailyPerformancePick: (r) => r.equityChange,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('权益信息'),
        const SizedBox(height: 8),
        _buildMetricsMonthNav(
          snapshots: snap,
          month: month,
          onMonthChanged: setEquityMonth,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: _kTripleMetricsRowHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _tripleMetricCard(
                  child: SizedBox.expand(
                    child: MonthEndValueCalendarPanel(
                      snapshots: snap,
                      title: '权益日历',
                      description: '',
                      valueAt: (s) => s.equityUsdt,
                      emptyMessage: '暂无日绩效或历史快照',
                      compact: true,
                      showMonthNavigator: false,
                      focusedMonth: month,
                      onFocusedMonthChanged: setEquityMonth,
                      expandGridArea: true,
                      titleToBodyExtraGap: _kProfileCalendarTitleExtraGap,
                      centerCalendarGridInExpanded: true,
                      dailyPerformanceRows: _equityPerfDays,
                      dailyPerformancePick: (r) => r.equityChange,
                    ),
                  ),
                ),
              ),
              SizedBox(width: _kTripleGutter),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _tripleMetricCard(
                        child: SizedBox.expand(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.max,
                            children: [
                              Text(
                                '权益曲线',
                                style:
                                    (Theme.of(context).textTheme.titleMedium ??
                                            const TextStyle())
                                        .copyWith(
                                          color: AppFinanceStyle.labelColor,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                              ),
                              const SizedBox(height: 6),
                              const SizedBox(height: 2),
                              Expanded(
                                child: SnapshotPercentLineChart(
                                  snapshots: snap,
                                  series: SnapshotReturnSeries.equity,
                                  compact: true,
                                  focusedMonth: month,
                                  dailyPerfDays: _equityPerfDays,
                                  monthPerformanceDenom: equityPctDenom > 1e-12
                                      ? equityPctDenom
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: _kTripleGutter),
                    Expanded(
                      child: _tripleMetricCard(
                        child: SizedBox.expand(
                          child: MonthEndValueBarPanel(
                            snapshots: snap,
                            title: '每日权益',
                            description: '',
                            valueAt: (s) => s.equityUsdt,
                            emptyMessage: '暂无日绩效或历史快照',
                            compact: true,
                            showMonthNavigator: false,
                            selectedEndMonth: month,
                            onSelectedEndMonthChanged: setEquityMonth,
                            expandChartArea: true,
                            maxBars: 8,
                            useDailyBarsForEndMonth: true,
                            dailyPerformanceRows: _equityPerfDays,
                            dailyPerformancePick: (r) => r.equityChange,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCashMetricsSection(bool wide) {
    if (_selectedAccount == null) return const SizedBox.shrink();
    final snap = _snapshots;
    final month = _cashMonthFor(snap);
    final cashPctDenom = _cashPctLineDenominator();
    void setCashMonth(DateTime d) {
      setState(() => _cashMetricsMonth = clampMonthToSnapshots(snap, d));
      unawaited(_syncDailyPerformanceForCharts());
    }

    if (!wide) {
      final calCap = _kUnifiedChartBandHeight;
      final plotH =
          calendarGridPixelHeightForCap(calCap, compact: false) *
          _kLineBarHeightFactor;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('现金信息'),
          const SizedBox(height: 8),
          _buildMetricsMonthNav(
            snapshots: snap,
            month: month,
            onMonthChanged: setCashMonth,
          ),
          const SizedBox(height: 12),
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
                    dailyPerfDays: _cashPerfDays,
                    monthPerformanceDenom: cashPctDenom > 1e-12
                        ? cashPctDenom
                        : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _glassCard(
            MonthEndValueBarPanel(
              snapshots: snap,
              title: '每日现金',
              description: '',
              valueAt: (s) => s.currentBalance,
              emptyMessage: '暂无日绩效或历史快照',
              showMonthNavigator: false,
              selectedEndMonth: month,
              onSelectedEndMonthChanged: setCashMonth,
              barChartHeight: plotH,
              maxBars: 8,
              useDailyBarsForEndMonth: true,
              dailyPerformanceRows: _cashPerfDays,
              dailyPerformancePick: (r) => r.cashChange,
            ),
          ),
          const SizedBox(height: 16),
          _glassCard(
            MonthEndValueCalendarPanel(
              snapshots: snap,
              title: '现金日历',
              description: '',
              valueAt: (s) => s.currentBalance,
              emptyMessage: '暂无日绩效或历史快照',
              showMonthNavigator: false,
              focusedMonth: month,
              onFocusedMonthChanged: setCashMonth,
              gridMaxHeight: plotH,
              titleToBodyExtraGap: _kProfileCalendarTitleExtraGap,
              dailyPerformanceRows: _cashPerfDays,
              dailyPerformancePick: (r) => r.cashChange,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('现金信息'),
        const SizedBox(height: 8),
        _buildMetricsMonthNav(
          snapshots: snap,
          month: month,
          onMonthChanged: setCashMonth,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: _kTripleMetricsRowHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _tripleMetricCard(
                  child: SizedBox.expand(
                    child: MonthEndValueCalendarPanel(
                      snapshots: snap,
                      title: '现金日历',
                      description: '',
                      valueAt: (s) => s.currentBalance,
                      emptyMessage: '暂无日绩效或历史快照',
                      compact: true,
                      showMonthNavigator: false,
                      focusedMonth: month,
                      onFocusedMonthChanged: setCashMonth,
                      expandGridArea: true,
                      titleToBodyExtraGap: _kProfileCalendarTitleExtraGap,
                      centerCalendarGridInExpanded: true,
                      dailyPerformanceRows: _cashPerfDays,
                      dailyPerformancePick: (r) => r.cashChange,
                    ),
                  ),
                ),
              ),
              SizedBox(width: _kTripleGutter),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _tripleMetricCard(
                        child: SizedBox.expand(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.max,
                            children: [
                              Text(
                                '现金曲线',
                                style:
                                    (Theme.of(context).textTheme.titleMedium ??
                                            const TextStyle())
                                        .copyWith(
                                          color: AppFinanceStyle.labelColor,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                              ),
                              const SizedBox(height: 6),
                              const SizedBox(height: 2),
                              Expanded(
                                child: SnapshotPercentLineChart(
                                  snapshots: snap,
                                  series: SnapshotReturnSeries.cash,
                                  compact: true,
                                  focusedMonth: month,
                                  dailyPerfDays: _cashPerfDays,
                                  monthPerformanceDenom: cashPctDenom > 1e-12
                                      ? cashPctDenom
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: _kTripleGutter),
                    Expanded(
                      child: _tripleMetricCard(
                        child: SizedBox.expand(
                          child: MonthEndValueBarPanel(
                            snapshots: snap,
                            title: '每日现金',
                            description: '',
                            valueAt: (s) => s.currentBalance,
                            emptyMessage: '暂无日绩效或历史快照',
                            compact: true,
                            showMonthNavigator: false,
                            selectedEndMonth: month,
                            onSelectedEndMonthChanged: setCashMonth,
                            expandChartArea: true,
                            maxBars: 8,
                            useDailyBarsForEndMonth: true,
                            dailyPerformanceRows: _cashPerfDays,
                            dailyPerformancePick: (r) => r.cashChange,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPositions({bool expandScroll = false}) {
    final longs = _positions.where((p) => p.posSide == 'long').toList();
    final shorts = _positions.where((p) => p.posSide == 'short').toList();
    final shortCost = _weightedAvgPx(shorts);
    final longCost = _weightedAvgPx(longs);
    final singleInst =
        _positions.isNotEmpty &&
        _positions.map((p) => p.instId).toSet().length == 1;
    final curPx = singleInst && _positions.isNotEmpty
        ? (_liveLastPx ?? _singleInstQuotePx())
        : 0.0;

    // 空仓/多仓标题：字号与字重与赛季列表中「收益金额 / 盈利率数值」行一致（bodyMedium+4、bold）；颜色另叠红/绿。
    final sideTitleStyle = TextStyle(
      fontWeight: FontWeight.bold,
      color: AppFinanceStyle.valueColor,
      fontSize: (Theme.of(context).textTheme.bodyMedium?.fontSize ?? 20) + 4,
    );
    TextStyle posQtyStyle(Color c) => AppFinanceStyle.valueTextStyle(
      context,
      fontSize: 18,
    ).copyWith(color: c);
    // 成本/均价/现价/标记：与账户详情数值同档字号；合约价经 [_fmtOkxContractPxForUi] ×1e9 再整数分组，避免极小价落成 0。
    final plWhiteStyle = AppFinanceStyle.valueTextStyle(
      context,
      fontSize: 18,
    ).copyWith(color: Colors.white);

    final positionsInner = _positions.isEmpty
        ? <Widget>[
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
            ),
          ]
        : <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),
                      Text(
                        '空仓',
                        style: sideTitleStyle.copyWith(
                          color: AppFinanceStyle.chartLoss,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '数量：${shorts.fold<int>(0, (s, p) => s + p.pos.abs().round())}',
                        style: posQtyStyle(AppFinanceStyle.chartLoss),
                      ),
                      const SizedBox(height: 3),
                      if (shorts.isNotEmpty && singleInst && curPx > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '盈亏：${formatUiSignedInteger(_totalDynUpl(shorts, curPx))}',
                            style: plWhiteStyle.copyWith(
                              color: AppFinanceStyle.chartLoss,
                              fontSize: 18,
                            ),
                          ),
                        )
                      else if (shorts.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '浮盈：${formatUiSignedInteger(shorts.fold<double>(0, (s, p) => s + p.upl))}',
                            style: plWhiteStyle.copyWith(
                              color: AppFinanceStyle.chartLoss,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const SizedBox(height: 12),
                      Text(
                        '多仓',
                        style: sideTitleStyle.copyWith(
                          color: AppFinanceStyle.chartProfit,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${longs.fold<int>(0, (s, p) => s + p.pos.round())}：数量',
                        style: posQtyStyle(AppFinanceStyle.chartProfit),
                      ),
                      const SizedBox(height: 3),
                      if (longs.isNotEmpty && singleInst && curPx > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${formatUiSignedInteger(_totalDynUpl(longs, curPx))}：盈亏',
                            style: plWhiteStyle.copyWith(
                              color: AppFinanceStyle.chartProfit,
                              fontSize: 18,
                            ),
                          ),
                        )
                      else if (longs.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '浮盈：${formatUiSignedInteger(longs.fold<double>(0, (s, p) => s + p.upl))}',
                            style: plWhiteStyle.copyWith(
                              color: AppFinanceStyle.chartProfit,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (singleInst && curPx > 0)
              _PriceAxisBar(
                shortCost: shortCost,
                longCost: longCost,
                liveLastPx: curPx,
                totalDynUpl: _totalDynUpl(_positions, curPx),
                labelColor: AppFinanceStyle.labelColor,
              )
            else
              ..._positions.map((p) {
                final side = p.posSide == 'long' ? '多' : '空';
                final small = Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppFinanceStyle.labelColor,
                );
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${p.instId} $side ${formatUiInteger(p.pos)}',
                        style: small,
                      ),
                      const SizedBox(height: 4),
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
          ];

    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          if (expandScroll)
            Expanded(
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: positionsInner,
                ),
              ),
            )
          else
            ...positionsInner,
        ],
      ),
    );
  }

  Widget _buildSeasons({bool expandScroll = false}) {
    final header = Text(
      '赛季盈利',
      style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle())
          .copyWith(
            color: AppFinanceStyle.labelColor,
            fontSize:
                (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 4,
          ),
    );
    final tableHead = Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(
            '收益',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppFinanceStyle.valueColor,
              fontSize:
                  (Theme.of(context).textTheme.bodyMedium?.fontSize ?? 16) + 2,
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
                  (Theme.of(context).textTheme.bodyMedium?.fontSize ?? 16) + 2,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
    final seasonsBody = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        tableHead,
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
                ? AppFinanceStyle.chartProfit
                : AppFinanceStyle.chartLoss;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(
                              _formatSeasonTime(s.startedAt),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: AppFinanceStyle.labelColor),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '-',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: AppFinanceStyle.labelColor),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatSeasonTime(s.stoppedAt),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: AppFinanceStyle.labelColor),
                            ),
                          ],
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
    );

    return _glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 8),
          if (expandScroll)
            Expanded(
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: seasonsBody,
              ),
            )
          else
            seasonsBody,
        ],
      ),
    );
  }
}

/// 与 [WebDashboardScreen] 中 `_SummaryCell` 一致：标签与数值横排、6px 间距、基线对齐；`trailingLabel` 控制 `textAlign`。
class _AccountDetailMetricCell extends StatelessWidget {
  const _AccountDetailMetricCell({
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

class _PriceAxisBar extends StatelessWidget {
  const _PriceAxisBar({
    required this.shortCost,
    required this.longCost,
    required this.liveLastPx,
    required this.totalDynUpl,
    this.labelColor,
  });

  final double? shortCost;
  final double? longCost;
  final double liveLastPx;
  final double totalDynUpl;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final lc = labelColor ?? const Color.fromRGBO(216, 216, 216, 1);
    final anchors = <double>[
      if (shortCost != null && shortCost! > 0) shortCost!,
      if (longCost != null && longCost! > 0) longCost!,
      if (liveLastPx > 0) liveLastPx,
    ];
    if (anchors.isEmpty) return const SizedBox.shrink();

    var axisLo = anchors.reduce(math.min);
    var axisHi = anchors.reduce(math.max);
    final span0 = axisHi - axisLo;
    final pad = span0 > 0
        ? span0 * 0.06
        : math.max(liveLastPx.abs() * 1e-4, 1e-6);
    axisLo -= pad;
    axisHi += pad;
    final span = axisHi - axisLo;
    final safeSpan = span <= 0 ? 1e-12 : span;

    double norm(double p) => ((p - axisLo) / safeSpan).clamp(0.0, 1.0);

    // 现价与账户详情主数值同档；浮动盈亏白色同档（与持仓区多/空仓盈亏一致）。
    final curPxStyle = AppFinanceStyle.valueTextStyle(
      context,
      fontSize: 20,
    ).copyWith(color: Colors.lightBlueAccent, fontWeight: FontWeight.w700);
    final floatPlStyle = AppFinanceStyle.valueTextStyle(
      context,
      fontSize: 20,
    ).copyWith(color: Colors.white);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 92,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final topColW = math.min(320.0, math.max(200.0, w * 0.42));
              final xCur = norm(liveLastPx) * w;
              final xShort = shortCost != null && shortCost! > 0
                  ? norm(shortCost!) * w
                  : null;
              final xLong = longCost != null && longCost! > 0
                  ? norm(longCost!) * w
                  : null;

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 44,
                    height: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: lc.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  if (xShort != null)
                    Positioned(
                      left: xShort - 1,
                      top: 40,
                      width: 2,
                      height: 14,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppFinanceStyle.chartLoss.withValues(
                            alpha: 0.9,
                          ),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  if (xLong != null)
                    Positioned(
                      left: xLong - 1,
                      top: 40,
                      width: 2,
                      height: 14,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppFinanceStyle.chartProfit.withValues(
                            alpha: 0.9,
                          ),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  Positioned(
                    left: xCur - 1.5,
                    top: 38,
                    width: 3,
                    height: 18,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
                  Positioned(
                    left: xCur,
                    top: 18, // 将top值下移，让"最新价格"在下方，"总浮动亏损"在上方
                    child: Transform.translate(
                      offset: Offset(-topColW / 2, 0),
                      child: SizedBox(
                        width: topColW,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              '总浮动亏损：${formatUiSignedInteger(totalDynUpl)}',
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              style: floatPlStyle.copyWith(fontSize: 16),
                            ),
                            const SizedBox(height: 12),

                            Text(
                              '最新价格： ${_fmtOkxContractPxForUi(liveLastPx)}',
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              style: curPxStyle.copyWith(fontSize: 16),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: shortCost != null && shortCost! > 0
                    ? Text(
                        '空 ${_fmtOkxContractPxForUi(shortCost!)}',
                        style:
                            AppFinanceStyle.valueTextStyle(
                              context,
                              fontSize: 18,
                            ).copyWith(
                              color: AppFinanceStyle.chartLoss,
                              fontWeight: FontWeight.w700,
                            ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: longCost != null && longCost! > 0
                    ? Text(
                        '${_fmtOkxContractPxForUi(longCost!)} 多',
                        style:
                            AppFinanceStyle.valueTextStyle(
                              context,
                              fontSize: 18,
                            ).copyWith(
                              color: AppFinanceStyle.chartProfit,
                              fontWeight: FontWeight.w700,
                            ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
