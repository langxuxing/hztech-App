import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';

/// 最近一次「测试账户」完整响应，用于卡片 checklist（内存态，刷新页面后清空）。
class _AccountTestRecord {
  const _AccountTestRecord({required this.at, required this.response});

  final DateTime at;
  final Map<String, dynamic> response;
}

/// 管理员维护 Account_List.json（侧栏「账户管理」）。
class WebAccountManagementScreen extends StatefulWidget {
  const WebAccountManagementScreen({super.key, this.embedInShell = false});

  final bool embedInShell;

  @override
  State<WebAccountManagementScreen> createState() =>
      _WebAccountManagementScreenState();
}

class _WebAccountManagementScreenState
    extends State<WebAccountManagementScreen> {
  final _prefs = SecurePrefs();
  List<AccountConfigRow> _accounts = [];
  bool _loading = true;
  String? _error;
  final Map<String, _AccountTestRecord> _testRecordByAccountId = {};

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final r = await api.adminListAccounts();
      if (!mounted) return;
      if (!r.success) {
        setState(() {
          _error = '加载失败';
          _loading = false;
        });
        return;
      }
      setState(() {
        _accounts = r.accounts;
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

  Future<void> _openEditor({AccountConfigRow? existing}) async {
    final accountIdCtrl = TextEditingController(
      text: existing?.accountId ?? '',
    );
    final nameCtrl = TextEditingController(text: existing?.accountName ?? '');
    final symbolCtrl = TextEditingController(text: existing?.symbol ?? '');
    final keyFileCtrl = TextEditingController(
      text: existing?.accountKeyFile ?? '',
    );
    final scriptCtrl = TextEditingController(text: existing?.scriptFile ?? '');
    final strategyCtrl = TextEditingController(
      text: existing?.tradingStrategy ?? '',
    );
    final capitalCtrl = TextEditingController(
      text: existing?.initialCapital != null
          ? '${existing!.initialCapital}'
          : '5000',
    );
    var enabled = existing?.enabled ?? true;
    final isNew = existing == null;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1e1e28),
            title: Text(
              isNew ? '新建账户' : '编辑账户',
              style: TextStyle(color: AppFinanceStyle.valueColor),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: accountIdCtrl,
                    enabled: isNew,
                    style: TextStyle(color: AppFinanceStyle.valueColor),
                    decoration: _dec(ctx, 'account_id（唯一）'),
                  ),
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(color: AppFinanceStyle.valueColor),
                    decoration: _dec(ctx, 'account_name'),
                  ),
                  TextField(
                    controller: symbolCtrl,
                    style: TextStyle(color: AppFinanceStyle.valueColor),
                    decoration: _dec(ctx, 'symbol 如 PEPE-USDT-SWAP'),
                  ),
                  TextField(
                    controller: keyFileCtrl,
                    style: TextStyle(color: AppFinanceStyle.valueColor),
                    decoration: _dec(ctx, 'account_key_file'),
                  ),
                  TextField(
                    controller: scriptCtrl,
                    style: TextStyle(color: AppFinanceStyle.valueColor),
                    decoration: _dec(ctx, 'script_file'),
                  ),
                  TextField(
                    controller: strategyCtrl,
                    style: TextStyle(color: AppFinanceStyle.valueColor),
                    decoration: _dec(ctx, 'trading_strategy'),
                  ),
                  TextField(
                    controller: capitalCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    style: TextStyle(color: AppFinanceStyle.valueColor),
                    decoration: _dec(ctx, 'Initial_capital'),
                  ),
                  SwitchListTile(
                    title: Text(
                      '启用 enbaled',
                      style: TextStyle(color: AppFinanceStyle.valueColor),
                    ),
                    value: enabled,
                    onChanged: (v) => setDlg(() => enabled = v),
                    activeThumbColor: AppFinanceStyle.profitGreenEnd,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );

    if (ok != true || !mounted) return;

    final row = AccountConfigRow(
      accountId: accountIdCtrl.text.trim(),
      accountName: nameCtrl.text.trim(),
      exchangeAccount: 'OKX',
      symbol: symbolCtrl.text.trim(),
      initialCapital: double.tryParse(capitalCtrl.text.trim()) ?? 0,
      tradingStrategy: strategyCtrl.text.trim(),
      accountKeyFile: keyFileCtrl.text.trim(),
      scriptFile: scriptCtrl.text.trim(),
      enabled: enabled,
    );

    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      if (isNew) {
        final r = await api.adminCreateAccount(row);
        if (!mounted) return;
        if (!r.success || r.account == null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('创建失败，请检查字段与唯一性')));
          return;
        }
      } else {
        final r = await api.adminUpdateAccount(
          existing.accountId,
          row.toJsonBody(),
        );
        if (!mounted) return;
        if (!r.success || r.account == null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('保存失败')));
          return;
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存；修改 account_id 后请同步用户绑定')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Widget _infoLine(BuildContext context, String label, String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text.rich(
        TextSpan(
          style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12),
          children: [
            TextSpan(text: '$label：'),
            TextSpan(
              text: v,
              style: TextStyle(color: AppFinanceStyle.valueColor),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic>? _asStringKeyMap(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) {
      return v.map((k, e) => MapEntry(k.toString(), e));
    }
    return null;
  }

  bool? _asBool(dynamic v) {
    if (v is bool) return v;
    return null;
  }

  String _fmtBalNum(double n) {
    if (n == n.roundToDouble()) return '${n.round()}';
    return n.toStringAsFixed(2);
  }

  ({String avail, String total, String locked}) _balanceDisplay(
    Map<String, dynamic>? bal,
  ) {
    double toD(dynamic x) {
      if (x == null) return 0;
      if (x is num) return x.toDouble();
      return double.tryParse(x.toString()) ?? 0;
    }

    if (bal == null) {
      return (avail: '—', total: '—', locked: '—');
    }
    final total = toD(bal['total_eq'] ?? bal['equity_usdt']);
    final avail = toD(
      bal['available_margin'] ?? bal['avail_eq'] ?? bal['cash_balance'],
    );
    var locked = total - avail;
    if (locked < 0) locked = 0;
    return (
      avail: _fmtBalNum(avail),
      total: _fmtBalNum(total),
      locked: _fmtBalNum(locked),
    );
  }

  ({String? long, String? short}) _leverageLongShortParse(
    dynamic levInfo,
    String instId,
  ) {
    String? l;
    String? s;
    final want = instId.trim();
    if (want.isEmpty) return (long: l, short: s);
    if (levInfo is List) {
      for (final raw in levInfo) {
        final item = _asStringKeyMap(raw);
        if (item == null) continue;
        if ('${item['instId'] ?? ''}'.trim() != want) continue;
        final ps = '${item['posSide'] ?? 'net'}'.toLowerCase().trim();
        final lv = item['lever']?.toString();
        if (lv == null || lv.isEmpty) continue;
        if (ps == 'long') {
          l = lv;
        } else if (ps == 'short') {
          s = lv;
        } else if (ps == 'net') {
          l = lv;
          s = lv;
        }
      }
    }
    return (long: l, short: s);
  }

  String _triStateLabel(bool? v) {
    if (v == true) return '是';
    if (v == false) return '否';
    return '未判定';
  }

  Widget _checklistGridCell(
    BuildContext context, {
    required int index,
    required String label,
    required String detail,
    required bool? ok,
  }) {
    final base = AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 13);
    late IconData icon;
    late Color color;
    if (ok == true) {
      icon = Icons.check_circle_outline;
      color = AppFinanceStyle.profitGreenEnd;
    } else if (ok == false) {
      icon = Icons.cancel_outlined;
      color = AppFinanceStyle.textDefault;
    } else {
      icon = Icons.help_outline;
      color = AppFinanceStyle.labelColor;
    }
    return Align(
      alignment: Alignment.topLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$index',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(
              color: AppFinanceStyle.valueColor,
              fontSize: 13,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  /// 单行 N 列网格（与校验项数量一致）；父级较窄时横向滚动。
  Widget _verificationChecklistGrid(BuildContext context, List<Widget> cells) {
    final n = cells.length;
    if (n == 0) return const SizedBox.shrink();
    const minCell = 118.0;
    const crossSpacing = 8.0;
    const gridHeight = 112.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final gridW = math.max(w, minCell * n);
        final inner = (gridW - (n - 1) * crossSpacing) / n;
        final aspect = inner / gridHeight;
        final grid = GridView.count(
          crossAxisCount: n,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: crossSpacing,
          mainAxisSpacing: 0,
          childAspectRatio: aspect,
          children: cells,
        );
        final boxed = SizedBox(width: gridW, height: gridHeight, child: grid);
        if (w.isFinite && gridW > w + 0.5) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: boxed,
          );
        }
        return boxed;
      },
    );
  }

  Widget _verificationChecklist(
    BuildContext context,
    Map<String, dynamic> m,
    AccountConfigRow row,
  ) {
    final okConn = m['success'] == true;
    if (!okConn) {
      return Text(
        m['message']?.toString() ?? '连接失败',
        style: AppFinanceStyle.labelTextStyle(
          context,
        ).copyWith(fontSize: 12, color: AppFinanceStyle.textLoss),
      );
    }
    final checks = _asStringKeyMap(m['checks']) ?? {};
    bool? chk(String k) => _asBool(checks[k]);

    final cap = row.initialCapital;
    final capStr = cap != null ? _fmtBalNum(cap) : '—';
    final capOk = cap != null && cap > 0;

    final inst = '${m['inst_id_checked'] ?? ''}'.trim();
    final fmtOk = chk('swap_symbol_format');
    final instOk = chk('swap_instrument_ok');
    final pairOk = fmtOk == true && instOk == true;

    final bidir = chk('pos_mode_long_short');
    final swapSup = chk('swap_instrument_ok');
    final cross = chk('mgn_mode_cross_ok');
    final levLOk = chk('leverage_long_ok');
    final levSOk = chk('leverage_short_ok');

    final levs = _leverageLongShortParse(m['leverage_info'], inst);
    final tgt = '${m['target_leverage'] ?? ''}'.trim();
    final tgtDisp = tgt.isEmpty ? '—' : '${tgt}x';
    final longDetail = levs.long != null
        ? '${levs.long}x（目标 $tgtDisp）'
        : '—（目标 $tgtDisp）';
    final shortDetail = levs.short != null
        ? '${levs.short}x（目标 $tgtDisp）'
        : '—（目标 $tgtDisp）';

    return _verificationChecklistGrid(context, [
      _checklistGridCell(
        context,
        index: 1,
        label: '初始资金',
        detail: capStr,
        ok: capOk,
      ),
      _checklistGridCell(
        context,
        index: 2,
        label: '交易对',
        detail: inst.isEmpty ? '—' : inst,
        ok: pairOk,
      ),
      _checklistGridCell(
        context,
        index: 3,
        label: '是否双向持仓',
        detail: _triStateLabel(bidir),
        ok: bidir,
      ),
      _checklistGridCell(
        context,
        index: 4,
        label: '是否支持合约',
        detail: _triStateLabel(swapSup),
        ok: swapSup,
      ),
      _checklistGridCell(
        context,
        index: 5,
        label: '是否全仓',
        detail: _triStateLabel(cross),
        ok: cross,
      ),
      _checklistGridCell(
        context,
        index: 6,
        label: '多仓的杠杆',
        detail: longDetail,
        ok: levLOk,
      ),
      _checklistGridCell(
        context,
        index: 7,
        label: '空仓的杠杆',
        detail: shortDetail,
        ok: levSOk,
      ),
    ]);
  }

  Widget _warningsSection(BuildContext context, Map<String, dynamic> m) {
    final warns = m['configuration_warnings'];
    if (warns is! List || warns.isEmpty) return const SizedBox.shrink();
    final base = AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('警告与说明', style: base.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          ...warns.map(
            (e) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: SelectableText(
                e.toString(),
                style: base.copyWith(color: AppFinanceStyle.textDefault),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 服务端在 `auto_configure` 请求下的 OKX 写操作步骤（双向持仓 / 全仓 / 多空杠杆）。
  Widget _autoConfigureSection(BuildContext context, Map<String, dynamic> m) {
    if (m['auto_configure'] != true) return const SizedBox.shrink();
    final base = AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12);
    final skipped = m['configure_skipped']?.toString().trim() ?? '';
    if (skipped.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: SelectableText(
          '自动配置：已跳过 — $skipped',
          style: base.copyWith(color: AppFinanceStyle.textDefault),
        ),
      );
    }
    final cr = m['configure_result'];
    if (cr is! Map) return const SizedBox.shrink();
    final ok = cr['ok'] == true;
    final steps = cr['steps'];
    final errs = cr['errors'];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自动配置 OKX（永续 SWAP、双向持仓、全仓、多空杠杆）',
            style: base.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          SelectableText(
            ok ? '执行结果：全部步骤成功' : '执行结果：存在失败步骤',
            style: TextStyle(
              color: ok
                  ? AppFinanceStyle.profitGreenEnd
                  : AppFinanceStyle.textDefault,
              fontSize: 12,
            ),
          ),
          if (steps is List && steps.isNotEmpty) ...[
            const SizedBox(height: 6),
            ...steps.map((s) {
              if (s is! Map) return const SizedBox.shrink();
              final name = s['name']?.toString() ?? '';
              final stepOk = s['ok'] == true;
              final det = s['detail']?.toString() ?? '';
              final line = det.isEmpty ? name : '$name — $det';
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: SelectableText(
                  '${stepOk ? "✓" : "✗"} $line',
                  style: base.copyWith(
                    color: stepOk
                        ? AppFinanceStyle.labelColor
                        : AppFinanceStyle.textDefault,
                  ),
                ),
              );
            }),
          ],
          if (errs is List && errs.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('错误摘要', style: base.copyWith(fontWeight: FontWeight.w600)),
            ...errs.map(
              (e) => SelectableText(
                e.toString(),
                style: base.copyWith(color: AppFinanceStyle.textLoss),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showTestAccountResultDialog(
    Map<String, dynamic> m,
    AccountConfigRow row,
  ) async {
    final ok = m['success'] == true;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final maxW = math.min(MediaQuery.sizeOf(ctx).width - 48, 1280.0);
        return AlertDialog(
          backgroundColor: const Color(0xFF1e1e28),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 40,
          ),
          title: Text(
            ok ? '测试账户' : '测试失败',
            style: TextStyle(color: AppFinanceStyle.valueColor),
          ),
          content: SizedBox(
            width: maxW,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (ok) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 1,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                m['configuration_ok'] == true
                                    ? '配置检查：通过'
                                    : '配置检查：未通过',
                                style: TextStyle(
                                  color: m['configuration_ok'] == true
                                      ? AppFinanceStyle.profitGreenEnd
                                      : AppFinanceStyle.textDefault,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '资金',
                                style: AppFinanceStyle.labelTextStyle(ctx)
                                    .copyWith(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              ...(() {
                                final bal = _asStringKeyMap(
                                  m['balance_summary'],
                                );
                                final d = _balanceDisplay(bal);
                                final base = TextStyle(
                                  color: AppFinanceStyle.valueColor,
                                  fontSize: 14,
                                  height: 1.35,
                                );
                                return [
                                  SelectableText(
                                    '可用：${d.avail} USDT',
                                    style: base,
                                  ),
                                  SelectableText(
                                    '总计：${d.total} USDT',
                                    style: base,
                                  ),
                                  SelectableText(
                                    '锁定：${d.locked} USDT',
                                    style: base,
                                  ),
                                ];
                              })(),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '验证结果',
                                style: AppFinanceStyle.labelTextStyle(ctx)
                                    .copyWith(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              _verificationChecklist(ctx, m, row),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    SelectableText(
                      m['message']?.toString() ?? '失败',
                      style: TextStyle(
                        color: AppFinanceStyle.textLoss,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  _autoConfigureSection(ctx, m),
                  _warningsSection(ctx, m),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  InputDecoration _dec(BuildContext context, String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: AppFinanceStyle.labelTextStyle(context),
      enabledBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: AppFinanceStyle.cardBorder),
      ),
    );
  }

  Future<void> _test(AccountConfigRow row, {bool autoConfigure = false}) async {
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final m = await api.adminTestAccountConnection(
        row.accountId,
        autoConfigure: autoConfigure,
      );
      if (!mounted) return;
      setState(() {
        _testRecordByAccountId[row.accountId] = _AccountTestRecord(
          at: DateTime.now(),
          response: m,
        );
      });
      await _showTestAccountResultDialog(m, row);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _delete(AccountConfigRow row) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账户配置'),
        content: Text('确定删除 ${row.accountId}？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final r = await api.adminDeleteAccount(row.accountId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(r.message ?? (r.success ? '已删除' : '失败'))),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final body = WaterBackground(
      child: _loading
          ? const Center(
              child: CircularProgressIndicator(
                color: AppFinanceStyle.profitGreenEnd,
              ),
            )
          : Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error!,
                      style: TextStyle(color: AppFinanceStyle.textLoss),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _accounts.length,
                    itemBuilder: (ctx, i) {
                      final a = _accounts[i];
                      final testRec = _testRecordByAccountId[a.accountId];
                      final name = a.accountName?.trim();
                      final titleLine = (name != null && name.isNotEmpty)
                          ? '$name (${a.accountId})'
                          : a.accountId;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: FinanceCard(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex: 1,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  titleLine,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: AppFinanceStyle
                                                        .valueColor,
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 15,
                                                  ),
                                                ),
                                              ),
                                              if (!a.enabled)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        left: 8,
                                                      ),
                                                  child: Text(
                                                    '已禁用',
                                                    style: TextStyle(
                                                      color: AppFinanceStyle
                                                          .labelColor,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 10),
                                          Text(
                                            '账户信息',
                                            style:
                                                AppFinanceStyle.labelTextStyle(
                                                  context,
                                                ).copyWith(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                  letterSpacing: 0.3,
                                                ),
                                          ),

                                          _infoLine(context, '标的', a.symbol),
                                          _infoLine(
                                            context,
                                            '密钥文件',
                                            a.accountKeyFile,
                                          ),
                                          _infoLine(
                                            context,
                                            '脚本',
                                            a.scriptFile,
                                          ),
                                          _infoLine(
                                            context,
                                            '策略',
                                            a.tradingStrategy,
                                          ),
                                          _infoLine(
                                            context,
                                            '初始资金',
                                            a.initialCapital != null
                                                ? '${a.initialCapital}'
                                                : null,
                                          ),

                                          if (testRec != null &&
                                              testRec.response['success'] ==
                                                  true) ...[
                                            const SizedBox(height: 10),
                                            Text(
                                              '资金',
                                              style:
                                                  AppFinanceStyle.labelTextStyle(
                                                    context,
                                                  ).copyWith(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    letterSpacing: 0.3,
                                                  ),
                                            ),
                                            const SizedBox(height: 4),
                                            Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: () {
                                                final bal = _asStringKeyMap(
                                                  testRec
                                                      .response['balance_summary'],
                                                );
                                                final d = _balanceDisplay(bal);
                                                final valStyle = TextStyle(
                                                  color: AppFinanceStyle
                                                      .valueColor,
                                                  fontSize: 12,
                                                );
                                                return [
                                                  Text.rich(
                                                    TextSpan(
                                                      style:
                                                          AppFinanceStyle.labelTextStyle(
                                                            context,
                                                          ).copyWith(
                                                            fontSize: 12,
                                                          ),
                                                      children: [
                                                        const TextSpan(
                                                          text: '可用：',
                                                        ),
                                                        TextSpan(
                                                          text: '${d.avail}',
                                                          style: valStyle,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  Text.rich(
                                                    TextSpan(
                                                      style:
                                                          AppFinanceStyle.labelTextStyle(
                                                            context,
                                                          ).copyWith(
                                                            fontSize: 12,
                                                          ),
                                                      children: [
                                                        const TextSpan(
                                                          text: '总计：',
                                                        ),
                                                        TextSpan(
                                                          text: '${d.total}',
                                                          style: valStyle,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  Text.rich(
                                                    TextSpan(
                                                      style:
                                                          AppFinanceStyle.labelTextStyle(
                                                            context,
                                                          ).copyWith(
                                                            fontSize: 12,
                                                          ),
                                                      children: [
                                                        const TextSpan(
                                                          text: '锁定：',
                                                        ),
                                                        TextSpan(
                                                          text: '${d.locked}',
                                                          style: valStyle,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ];
                                              }(),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 18),
                                    Expanded(
                                      flex: 3,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (testRec != null) ...[
                                            Text(
                                              '测试验证（${testRec.at.hour.toString().padLeft(2, '0')}:${testRec.at.minute.toString().padLeft(2, '0')}）',
                                              style:
                                                  AppFinanceStyle.labelTextStyle(
                                                    context,
                                                  ).copyWith(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                            const SizedBox(height: 18),
                                            _verificationChecklist(
                                              context,
                                              testRec.response,
                                              a,
                                            ),
                                          ] else
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 6,
                                              ),
                                              child: Text(
                                                '尚未测试；点击右侧「测试账户」后在此显示验证结果',
                                                style:
                                                    AppFinanceStyle.labelTextStyle(
                                                      context,
                                                    ).copyWith(fontSize: 13),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: () => _openEditor(existing: a),
                                    child: const Text('编辑'),
                                  ),
                                  TextButton(
                                    onPressed: () => _test(a),
                                    child: const Text('账户测试'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        _test(a, autoConfigure: true),
                                    child: const Text('自动配置'),
                                  ),
                                  TextButton(
                                    onPressed: () => _delete(a),
                                    child: Text(
                                      '删除',
                                      style: TextStyle(
                                        color: AppFinanceStyle.textLoss,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );

    final fab = FloatingActionButton.extended(
      onPressed: () => _openEditor(),
      backgroundColor: AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.3),
      foregroundColor: AppFinanceStyle.profitGreenStart,
      icon: const Icon(Icons.add),
      label: const Text('新建账户'),
    );

    if (widget.embedInShell) {
      return Stack(
        children: [
          body,
          Positioned(right: 16, bottom: 16, child: fab),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '账户管理',
          style: AppFinanceStyle.labelTextStyle(
            context,
          ).copyWith(color: AppFinanceStyle.valueColor, fontSize: 18),
        ),
        backgroundColor: AppFinanceStyle.backgroundDark,
        foregroundColor: AppFinanceStyle.valueColor,
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Stack(
        children: [
          body,
          Positioned(right: 16, bottom: 16, child: fab),
        ],
      ),
    );
  }
}
