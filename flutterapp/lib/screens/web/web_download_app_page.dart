import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/client.dart';
import '../../constants/app_download.dart';
import '../../secure/prefs.dart';
import '../../theme/finance_style.dart';
import '../../widgets/water_background.dart';

class WebDownloadAppPage extends StatefulWidget {
  const WebDownloadAppPage({super.key});

  @override
  State<WebDownloadAppPage> createState() => _WebDownloadAppPageState();
}

class _WebDownloadAppPageState extends State<WebDownloadAppPage> {
  final _prefs = SecurePrefs();
  String? _baseUrl;
  /// 与 GET /api/app-version 的 android.apk_filename 一致（本地 debug / 线上 release 由后端决定）
  String _apkFileName = kDefaultApkFileName;

  static String _normalizeBackendBase(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    return t.startsWith('http') ? t : 'http://$t';
  }

  @override
  void initState() {
    super.initState();
    _prefs.backendBaseUrl.then((u) async {
      final trimmed = u.trim();
      if (!mounted) return;
      setState(() => _baseUrl = trimmed.isEmpty ? null : trimmed);
      if (trimmed.isEmpty) return;
      final base = _normalizeBackendBase(trimmed);
      try {
        final cfg = await ApiClient(base).getAppVersionConfig();
        if (!mounted || cfg == null || !cfg.success) return;
        final name = cfg.android.apkFilename?.trim();
        if (name != null && name.isNotEmpty) {
          setState(() => _apkFileName = name);
        }
      } catch (_) {
        // 网络或旧后端：沿用 kDefaultApkFileName
      }
    });
  }

  Uri? _apkUri() {
    final raw = _baseUrl;
    if (raw == null || raw.isEmpty) return null;
    final u = raw.startsWith('http') ? raw : 'http://$raw';
    final base = u.endsWith('/') ? u : '$u/';
    final path = 'api/download/apk/${Uri.encodeComponent(_apkFileName)}';
    return Uri.parse('$base$path');
  }

  Future<void> _openApk() async {
    final uri = _apkUri();
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置中配置后端地址')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开下载链接')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uri = _apkUri();
    return ColoredBox(
      color: AppFinanceStyle.backgroundDark,
      child: WaterBackground(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: FinanceCard(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '下载 Android 客户端',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: AppFinanceStyle.valueColor,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '安装包由当前后端提供：',
                    style: AppFinanceStyle.labelTextStyle(context),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    uri?.toString() ?? '（未配置后端地址）',
                    style: const TextStyle(
                      color: AppFinanceStyle.valueColor,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: uri != null ? _openApk : null,
                    icon: const Icon(Icons.download),
                    label: const Text('下载 APK'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
