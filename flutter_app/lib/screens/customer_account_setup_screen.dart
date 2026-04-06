import 'dart:convert';

import 'package:flutter/material.dart';
import '../api/client.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../widgets/water_background.dart';

/// 客户：为管理员已绑定的 account_id 上传 OKX 密钥 JSON，并测连（含 SWAP/双向/50x 检查）。
class CustomerAccountSetupScreen extends StatefulWidget {
  const CustomerAccountSetupScreen({super.key, this.embedInShell = false});

  final bool embedInShell;

  @override
  State<CustomerAccountSetupScreen> createState() =>
      _CustomerAccountSetupScreenState();
}

class _CustomerAccountSetupScreenState extends State<CustomerAccountSetupScreen> {
  final _prefs = SecurePrefs();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final m = await api.getCustomerLinkedAccounts();
      if (!mounted) return;
      if (m['success'] != true) {
        setState(() {
          _error = m['message']?.toString() ?? '加载失败';
          _loading = false;
        });
        return;
      }
      final raw = m['accounts'];
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map<String, dynamic>) {
            list.add(e);
          } else if (e is Map) {
            list.add(Map<String, dynamic>.from(e));
          }
        }
      }
      setState(() {
        _rows = list;
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

  Future<void> _pasteJson(String accountId) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e1e28),
        title: Text(
          '粘贴 OKX 密钥 JSON',
          style: TextStyle(color: AppFinanceStyle.valueColor),
        ),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            maxLines: 14,
            style: TextStyle(
              color: AppFinanceStyle.valueColor,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
            decoration: InputDecoration(
              hintText: '{"api":{"key":"...","secret":"...","passphrase":"..."}}',
              hintStyle: TextStyle(color: AppFinanceStyle.labelColor),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存到服务器'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Map<String, dynamic>? parsed;
    try {
      final o = jsonDecode(ctrl.text.trim());
      if (o is Map<String, dynamic>) {
        parsed = o;
      } else if (o is Map) {
        parsed = Map<String, dynamic>.from(o);
      }
    } catch (_) {}
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('JSON 格式无效')),
      );
      return;
    }
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final r = await api.putCustomerOkxJson(accountId, parsed);
      if (!mounted) return;
      if (r['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r['message']?.toString() ?? '保存失败')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存密钥文件')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _test(String accountId) async {
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final m = await api.customerTestAccountConnection(accountId);
      if (!mounted) return;
      final ok = m['success'] == true;
      final cfgOk = m['configuration_ok'] == true;
      final warns = m['configuration_warnings'];
      final buf = StringBuffer();
      if (ok) {
        buf.write('连接: 成功。配置检查: ${cfgOk ? "通过" : "未通过"}。\n');
        buf.write(
          '标的: ${m['inst_id_checked'] ?? ''}，目标杠杆: ${m['target_leverage'] ?? 50}x\n',
        );
        buf.write('余额摘要: ${m['balance_summary']}');
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
            buf.write('\n【用户标识】OKX uid: $uid');
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
            ok ? '测连结果' : '测连失败',
            style: TextStyle(color: AppFinanceStyle.valueColor),
          ),
          content: SingleChildScrollView(
            child: SelectableText(
              buf.toString(),
              style: TextStyle(
                color: ok
                    ? AppFinanceStyle.labelColor
                    : Colors.red.shade200,
                fontSize: 12,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error!,
                      style: TextStyle(color: Colors.red.shade300),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '请粘贴与 QTrader 一致的 OKX JSON（含 api.key / secret / passphrase）。'
                    '管理员须先在「账户管理」中创建账户并为您绑定 account_id，symbol 须为永续如 PEPE-USDT-SWAP。',
                    style: AppFinanceStyle.labelTextStyle(context).copyWith(
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _rows.length,
                    itemBuilder: (ctx, i) {
                      final r = _rows[i];
                      final aid = r['account_id']?.toString() ?? '';
                      final missing = r['missing_in_account_list'] == true;
                      final sym = r['symbol']?.toString() ?? '';
                      final keyOk = r['key_file_exists'] == true;
                      final name = r['account_name']?.toString() ?? '';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: FinanceCard(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                aid,
                                style: TextStyle(
                                  color: AppFinanceStyle.valueColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (name.isNotEmpty)
                                Text(
                                  name,
                                  style: AppFinanceStyle.labelTextStyle(
                                    context,
                                  ),
                                ),
                              const SizedBox(height: 6),
                              if (missing)
                                Text(
                                  '服务端 Account_List 中无此账户，请联系管理员',
                                  style: TextStyle(color: Colors.orange.shade200),
                                )
                              else ...[
                                Text(
                                  '$sym · 密钥文件: ${keyOk ? "已上传" : "未上传"}',
                                  style: AppFinanceStyle.labelTextStyle(context)
                                      .copyWith(fontSize: 12),
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    TextButton(
                                      onPressed: missing
                                          ? null
                                          : () => _pasteJson(aid),
                                      child: const Text('粘贴并保存 JSON'),
                                    ),
                                    TextButton(
                                      onPressed:
                                          missing ? null : () => _test(aid),
                                      child: const Text('测试连接与配置'),
                                    ),
                                  ],
                                ),
                              ],
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

    if (widget.embedInShell) {
      return body;
    }

    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: AppBar(
        title: Text(
          '账户配置',
          style: AppFinanceStyle.labelTextStyle(context).copyWith(
                color: AppFinanceStyle.valueColor,
                fontSize: 18,
              ),
        ),
        backgroundColor: AppFinanceStyle.backgroundDark,
        foregroundColor: AppFinanceStyle.valueColor,
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: body,
    );
  }
}
