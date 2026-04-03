import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../widgets/water_background.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onLogout, this.embedInShell = false});

  final VoidCallback? onLogout;

  /// 嵌入 Web 主导航壳时不显示本页 [AppBar]。
  final bool embedInShell;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _prefs = SecurePrefs();
  late TextEditingController _urlCtrl;
  bool _fingerprintEnabled = false;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final url = await _prefs.backendBaseUrl;
    final fp = await _prefs.fingerprintEnabled;
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = url;
      _fingerprintEnabled = fp;
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入后端地址')),
      );
      return;
    }
    await _prefs.setBackendBaseUrl(url);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
  }

  Future<void> _toggleFingerprint(bool value) async {
    await _prefs.setFingerprintEnabled(value);
    setState(() => _fingerprintEnabled = value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value ? '已开启指纹登录' : '已关闭指纹登录')),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出登录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _prefs.clearOnLogout();
    if (!mounted) return;
    widget.onLogout?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      appBar: widget.embedInShell
          ? null
          : AppBar(
              title: Text(
                '设置',
                style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  color: AppFinanceStyle.valueColor,
                  fontSize: 18,
                ),
              ),
              backgroundColor: AppFinanceStyle.backgroundDark,
              foregroundColor: AppFinanceStyle.valueColor,
              surfaceTintColor: Colors.transparent,
            ),
      body: WaterBackground(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                children: [
                  FinanceCard(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('后端地址', style: AppFinanceStyle.labelTextStyle(context)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _urlCtrl,
                          style: const TextStyle(color: AppFinanceStyle.valueColor, fontSize: 16),
                          decoration: InputDecoration(
                            hintText: 'https://your-server/',
                            hintStyle: TextStyle(color: AppFinanceStyle.labelColor.withValues(alpha: 0.8)),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: AppFinanceStyle.cardBorder),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: AppFinanceStyle.profitGreenEnd, width: 1.5),
                            ),
                          ),
                          keyboardType: TextInputType.url,
                          cursorColor: AppFinanceStyle.profitGreenEnd,
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(double.infinity, 48),
                              backgroundColor: AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.25),
                              foregroundColor: AppFinanceStyle.profitGreenStart,
                            ),
                            onPressed: _saveUrl,
                            child: const Text('保存地址'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!kIsWeb) ...[
                    const SizedBox(height: 20),
                    FinanceCard(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      child: SwitchListTile(
                        title: Text('指纹登录', style: AppFinanceStyle.labelTextStyle(context).copyWith(color: AppFinanceStyle.valueColor)),
                        value: _fingerprintEnabled,
                        onChanged: _toggleFingerprint,
                        activeColor: AppFinanceStyle.profitGreenEnd,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FinanceCard(
                      padding: const EdgeInsets.all(20),
                      child: SizedBox(
                        width: double.infinity,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('权限说明', style: AppFinanceStyle.labelTextStyle(context).copyWith(color: AppFinanceStyle.valueColor, fontSize: 16)),
                            const SizedBox(height: 8),
                            Text(
                              '若提示「已拒绝敏感权限」或指纹/网络不可用，请在系统设置中为本应用开启：\n'
                              '· 网络（访问后端与账户数据）\n'
                              '· 生物识别/指纹（指纹登录）',
                              style: AppFinanceStyle.labelTextStyle(context).copyWith(fontSize: 13, height: 1.4),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.tonalIcon(
                              onPressed: () async {
                                await openAppSettings();
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: AppFinanceStyle.cardBorder.withValues(alpha: 0.5),
                                foregroundColor: AppFinanceStyle.valueColor,
                              ),
                              icon: const Icon(Icons.settings, size: 20),
                              label: const Text('打开应用设置'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _logout(context),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    backgroundColor: Colors.red.withValues(alpha: 0.25),
                    foregroundColor: Colors.red.shade300,
                  ),
                  child: const Text('退出登录'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
