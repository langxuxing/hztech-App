import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../utils/number_display_format.dart';
import '../widgets/water_background.dart';
import 'account_profit_screen.dart';

/// 移动端「账户管理」汇总列表；点击进「账户收益」，数据字段与 Web「账户画像」一致（权益、现金、浮动、收益率等）。
///
/// [sharedBots] 由 [MainScreen] 下发时与账户收益页同源，避免下拉框空窗；为空则本页并行请求 `/api/tradingbots`。
class AccountsList extends StatefulWidget {
  const AccountsList({super.key, this.sharedBots = const []});

  final List<UnifiedTradingBot> sharedBots;

  @override
  State<AccountsList> createState() => _AccountsListState();
}

class _AccountsListState extends State<AccountsList> {
  final _prefs = SecurePrefs();
  List<AccountProfit> _accounts = [];
  /// 仅当 [widget.sharedBots] 为空时由本页拉取填充。
  List<UnifiedTradingBot> _fetchedBots = [];
  bool _loading = true;
  String? _error;

  List<UnifiedTradingBot> get _effectiveBots =>
      widget.sharedBots.isNotEmpty ? widget.sharedBots : _fetchedBots;

  UnifiedTradingBot? _botFor(String botId) {
    if (botId.isEmpty) return null;
    for (final b in _effectiveBots) {
      if (b.tradingbotId == botId) return b;
    }
    return null;
  }

  /// 与 Web 顶栏账户顺序一致：按 tradingbots 列表排序，其余账户排在后面。
  List<AccountProfit> get _orderedAccounts {
    final list = List<AccountProfit>.from(_accounts);
    final order = _effectiveBots.map((b) => b.tradingbotId).toList();
    if (order.isEmpty) return list;
    int rank(String id) {
      final i = order.indexOf(id);
      return i < 0 ? 1 << 30 : i;
    }

    list.sort((a, b) => rank(a.botId).compareTo(rank(b.botId)));
    return list;
  }

  String _primaryLabel(AccountProfit a) {
    final ex = a.exchangeAccount.trim();
    if (ex.isNotEmpty) return ex;
    return a.botId.isNotEmpty ? a.botId : '—';
  }

  String? _secondaryLabel(AccountProfit a) {
    final bot = _botFor(a.botId);
    final name = bot?.tradingbotName?.trim();
    final primary = _primaryLabel(a);
    if (name != null && name.isNotEmpty && name != primary) return name;
    if (a.botId.isNotEmpty && a.botId != primary) return a.botId;
    return null;
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
      late final AccountProfitResponse profitResp;
      List<UnifiedTradingBot> bots = List.from(widget.sharedBots);
      if (widget.sharedBots.isEmpty) {
        final pair = await Future.wait([
          api.getAccountProfit(),
          api.getTradingBots(),
        ]);
        profitResp = pair[0] as AccountProfitResponse;
        bots = (pair[1] as TradingBotsResponse).botList;
      } else {
        profitResp = await api.getAccountProfit();
      }
      if (!mounted) return;
      setState(() {
        _accounts = profitResp.accounts ?? [];
        _fetchedBots = bots;
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

  static const _barBg = AppFinanceStyle.backgroundDark;
  static const _barTextColor = AppFinanceStyle.valueColor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '账户管理',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(
            color: _barTextColor,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: _barBg,
        foregroundColor: _barTextColor,
        surfaceTintColor: Colors.transparent,
      ),
      body: WaterBackground(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading && _accounts.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _accounts.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.3,
                        ),
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Column(
                              children: [
                                Text(_error!, textAlign: TextAlign.center),
                                const SizedBox(height: 16),
                                FilledButton(onPressed: _load, child: const Text('重试')),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        FinanceCard(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    color: AppFinanceStyle.valueColor,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      '点击账户进入「账户收益」：账户详情、持仓与赛季、权益/现金曲线与月历等与 Web「账户画像」一致。',
                                      style: AppFinanceStyle.labelTextStyle(context),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '脚本启停仍在底部「策略启停」。数据来源：/api/account-profit 与 /api/tradingbots。',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.outline,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '账户概览（${_accounts.length}）',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: AppFinanceStyle.valueColor,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 12),
                        if (_accounts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                '暂无账户数据',
                                style: AppFinanceStyle.labelTextStyle(context),
                              ),
                            ),
                          )
                        else
                          ..._orderedAccounts.map(
                            (a) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (ctx) => AccountProfitScreen(
                                          sharedBots: _effectiveBots,
                                          initialBotId:
                                              a.botId.isNotEmpty ? a.botId : null,
                                        ),
                                      ),
                                    );
                                  },
                                  borderRadius: BorderRadius.circular(12),
                                  child: FinanceCard(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                _primaryLabel(a),
                                                style: Theme.of(context)
                                                    .textTheme.titleSmall
                                                    ?.copyWith(
                                                      color: AppFinanceStyle
                                                          .valueColor,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                              ),
                                              if (_secondaryLabel(a) != null) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  _secondaryLabel(a)!,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .outline,
                                                      ),
                                                ),
                                              ],
                                              const SizedBox(height: 6),
                                              Text(
                                                '余额 ${formatUiInteger(a.cashBalance ?? a.balanceUsdt)} · 浮动 ${formatUiSignedInteger(a.floatingProfit)}',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .outline,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              '权益 ${formatUiInteger(a.equityUsdt)}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium
                                                  ?.copyWith(
                                                    color: AppFinanceStyle
                                                        .textProfit,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                            Text(
                                              formatUiPercentLabel(
                                                a.profitPercent,
                                              ),
                                              style: AppFinanceStyle
                                                  .labelTextStyle(context)
                                                  .copyWith(
                                                    color: a.profitPercent >= 0
                                                        ? AppFinanceStyle
                                                            .textProfit
                                                        : AppFinanceStyle
                                                            .textLoss,
                                                  ),
                                            ),
                                          ],
                                        ),
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
      ),
    );
  }
}
