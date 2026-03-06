import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../secure/prefs.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onLogout});

  final VoidCallback? onLogout;

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
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: '后端地址',
              border: OutlineInputBorder(),
              hintText: 'https://your-server/',
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
            onPressed: _saveUrl,
            child: const Text('保存地址'),
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            title: const Text('指纹登录'),
            value: _fingerprintEnabled,
            onChanged: _toggleFingerprint,
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '权限说明',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '若提示「已拒绝敏感权限」或指纹/网络不可用，请在系统设置中为本应用开启：\n'
                    '· 网络（访问后端与账户数据）\n'
                    '· 生物识别/指纹（指纹登录）',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await openAppSettings();
                    },
                    icon: const Icon(Icons.settings),
                    label: const Text('打开应用设置'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.tonal(
            onPressed: () => _logout(context),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
  }
}
