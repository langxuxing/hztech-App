import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';

/// 最近一次「测连 OKX」结果，用于卡片展示（内存态，刷新页面后清空）。
class _AccountTestSummary {
  const _AccountTestSummary({
    required this.at,
    required this.connectionOk,
    required this.configurationOk,
    this.message,
    this.instId,
    this.targetLeverage,
    this.balanceSummary,
    this.okxUid,
  });

  final DateTime at;
  final bool connectionOk;
  final bool configurationOk;
  final String? message;
  final String? instId;
  final String? targetLeverage;
  final String? balanceSummary;
  final String? okxUid;

  static _AccountTestSummary fromApiMap(Map<String, dynamic> m) {
    final ok = m['success'] == true;
    if (!ok) {
      return _AccountTestSummary(
        at: DateTime.now(),
        connectionOk: false,
        configurationOk: false,
        message: m['message']?.toString(),
      );
    }
    final cfgOk = m['configuration_ok'] == true;
    String? uid;
    final ac = m['account_config'];
    if (ac is Map) {
      final u = ac['uid'];
      if (u != null && '$u'.trim().isNotEmpty) uid = '$u';
    }
    return _AccountTestSummary(
      at: DateTime.now(),
      connectionOk: true,
      configurationOk: cfgOk,
      instId: m['inst_id_checked']?.toString(),
      targetLeverage: m['target_leverage']?.toString(),
      balanceSummary: m['balance_summary']?.toString(),
      okxUid: uid,
    );
  }
}

/// 管理员维护 Account_List.json（侧栏「账号管理」）。
class WebAccountConfigAdminScreen extends StatefulWidget {
  const WebAccountConfigAdminScreen({super.key, this.embedInShell = false});

  final bool embedInShell;

  @override
  State<WebAccountConfigAdminScreen> createState() =>
      _WebAccountConfigAdminScreenState();
}

class _WebAccountConfigAdminScreenState
    extends State<WebAccountConfigAdminScreen> {
  final _prefs = SecurePrefs();
  List<AccountConfigRow> _accounts = [];
  bool _loading = true;
  String? _error;
  final Map<String, _AccountTestSummary> _testSummaryByAccountId = {};

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

  Widget _testSummaryBody(BuildContext context, _AccountTestSummary s) {
    final base = AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 12);
    if (!s.connectionOk) {
      return Text(
        s.message ?? '连接失败',
        style: base.copyWith(color: Colors.red.shade200),
      );
    }
    final cfgText = s.configurationOk ? '通过' : '未通过';
    final cfgColor = s.configurationOk
        ? AppFinanceStyle.profitGreenEnd
        : Colors.orange.shade200;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            style: base,
            children: [
              const TextSpan(text: '连接：'),
              TextSpan(
                text: '成功',
                style: TextStyle(color: AppFinanceStyle.profitGreenEnd),
              ),
              const TextSpan(text: '　配置检查：'),
              TextSpan(text: cfgText, style: TextStyle(color: cfgColor)),
            ],
          ),
        ),
        if (s.instId != null && s.instId!.isNotEmpty)
          Text(
            '标的：${s.instId}　杠杆：${s.targetLeverage ?? '—'}x',
            style: base,
          ),
        if (s.balanceSummary != null && s.balanceSummary!.isNotEmpty)
          Text('余额：${s.balanceSummary}', style: base),
        if (s.okxUid != null && s.okxUid!.isNotEmpty)
          Text('OKX uid：${s.okxUid}', style: base),
      ],
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

  Future<void> _test(AccountConfigRow row) async {
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final m = await api.adminTestAccountConnection(row.accountId);
      if (!mounted) return;
      final summary = _AccountTestSummary.fromApiMap(m);
      setState(() {
        _testSummaryByAccountId[row.accountId] = summary;
      });
      final ok = m['success'] == true;
      final cfgOk = m['configuration_ok'] == true;
      final warns = m['configuration_warnings'];
      final buf = StringBuffer();
      if (ok) {
        buf.write('连接: 成功。配置检查: ${cfgOk ? "通过" : "未通过"}。');
        buf.write('\n标的: ${m['inst_id_checked'] ?? ''}，目标杠杆: ${m['target_leverage'] ?? ''}x');
        buf.write('\n余额摘要: ${m['balance_summary']}');
        final checks = m['checks'];
        buf.write('\n\n【检查项】');
        if (checks != null) {
          try {
            buf.write('\n${const JsonEncoder.withIndent('  ').convert(checks)}');
          } catch (_) {
            buf.write('\n$checks');
          }
        } else {
          buf.write('\n（无）');
        }
        final ac = m['account_config'];
        buf.write('\n\n【账户配置】（OKX GET /api/v5/account/config）');
        if (ac is Map && ac.isNotEmpty) {
          try {
            buf.write('\n${const JsonEncoder.withIndent('  ').convert(ac)}');
          } catch (_) {
            buf.write('\n$ac');
          }
          final uid = ac['uid'];
          if (uid != null && '$uid'.trim().isNotEmpty) {
            buf.write('\nOKX 用户标识 uid: $uid');
          }
        } else {
          buf.write('\n（无数据：账户配置接口未返回有效内容，请查看下方警告）');
        }
        final lev = m['leverage_info'];
        buf.write('\n\n【杠杆信息】');
        if (lev != null) {
          try {
            buf.write('\n${const JsonEncoder.withIndent('  ').convert(lev)}');
          } catch (_) {
            buf.write('\n$lev');
          }
        } else {
          buf.write('\n（无）');
        }
      } else {
        buf.write(m['message']?.toString() ?? '失败');
      }
      if (warns is List && warns.isNotEmpty) {
        buf.write('\n\n【警告与说明】\n');
        buf.writeAll(warns.map((e) => e.toString()), '\n');
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1e1e28),
          title: Text(
            ok ? '测连 OKX' : '测连失败',
            style: TextStyle(color: AppFinanceStyle.valueColor),
          ),
          content: SingleChildScrollView(
            child: SelectableText(
              buf.toString(),
              style: TextStyle(
                color: ok ? AppFinanceStyle.labelColor : Colors.red.shade200,
                fontSize: 13,
                height: 1.35,
                fontFamily: 'monospace',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
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
                      style: TextStyle(color: Colors.red.shade300),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _accounts.length,
                    itemBuilder: (ctx, i) {
                      final a = _accounts[i];
                      final sum = _testSummaryByAccountId[a.accountId];
                      final name = a.accountName?.trim();
                      final titleLine = (name != null && name.isNotEmpty)
                          ? '$name (${a.accountId})'
                          : a.accountId;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: FinanceCard(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      titleLine,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: AppFinanceStyle.valueColor,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ),
                                  if (!a.enabled)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 8),
                                      child: Text(
                                        '已禁用',
                                        style: TextStyle(
                                          color: AppFinanceStyle.labelColor,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                '基本信息',
                                style: AppFinanceStyle.labelTextStyle(
                                  context,
                                ).copyWith(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.3,
                                ),
                              ),
                              const SizedBox(height: 4),
                              _infoLine(context, '标的', a.symbol),
                              _infoLine(context, '密钥文件', a.accountKeyFile),
                              _infoLine(context, '脚本', a.scriptFile),
                              _infoLine(context, '策略', a.tradingStrategy),
                              _infoLine(
                                context,
                                '初始资金',
                                a.initialCapital != null
                                    ? '${a.initialCapital}'
                                    : null,
                              ),
                              _infoLine(context, '交易所', a.exchangeAccount),
                              if (sum != null) ...[
                                const SizedBox(height: 10),
                                Divider(
                                  height: 1,
                                  color: AppFinanceStyle.cardBorder
                                      .withValues(alpha: 0.6),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '测连验证（${sum.at.hour.toString().padLeft(2, '0')}:${sum.at.minute.toString().padLeft(2, '0')}）',
                                  style: AppFinanceStyle.labelTextStyle(
                                    context,
                                  ).copyWith(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                _testSummaryBody(context, sum),
                              ] else
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    '尚未测连；点击下方「测连 OKX」后在此显示验证摘要',
                                    style: AppFinanceStyle.labelTextStyle(
                                      context,
                                    ).copyWith(fontSize: 12),
                                  ),
                                ),
                              const SizedBox(height: 12),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  TextButton(
                                    onPressed: () => _openEditor(existing: a),
                                    child: const Text('编辑'),
                                  ),
                                  const Spacer(),
                                  TextButton(
                                    onPressed: () => _test(a),
                                    child: const Text('测连 OKX'),
                                  ),
                                  const SizedBox(width: 4),
                                  TextButton(
                                    onPressed: () => _delete(a),
                                    child: Text(
                                      '删除',
                                      style: TextStyle(
                                        color: Colors.red.shade300,
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
          '账号管理',
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
