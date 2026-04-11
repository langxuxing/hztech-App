import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api/client.dart';
import 'api/models.dart';
import 'constants/app_download.dart'
    show kApkDownloadUrlPath, kAwsApkStorageBaseUrl, kDefaultApkFileName;
import 'version_utils.dart';

/// 打包 iOS 时可传入：`--dart-define=IOS_APP_STORE_URL=https://apps.apple.com/...`
const String _kIosStoreUrlFromDefine = String.fromEnvironment(
  'IOS_APP_STORE_URL',
  defaultValue: '',
);

bool _isAndroidMobile() {
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}

bool _isIosMobile() {
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
}

String _normalizeBase(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  final u = t.startsWith('http') ? t : 'http://$t';
  return u.endsWith('/') ? u : '$u/';
}

Uri? _androidApkUri(String base, String fileName) {
  final b = _normalizeBase(base);
  if (b.isEmpty) return null;
  final name = fileName.trim().isEmpty ? kDefaultApkFileName : fileName.trim();
  return Uri.parse('$b$kApkDownloadUrlPath/${Uri.encodeComponent(name)}');
}

/// 优先使用线上公开下载域名（与登录页 APK 直链一致），避免 API 与 APK 分机部署时链到无文件的 API。
Uri? _androidApkUriPreferPublic(String backendBaseUrl, String fileName) {
  if (kAwsApkStorageBaseUrl.trim().isNotEmpty) {
    return _androidApkUri(kAwsApkStorageBaseUrl, fileName);
  }
  return _androidApkUri(backendBaseUrl, fileName);
}

/// 本会话内用户点了「稍后」则不再弹可选升级（低于 [latest]）；低于 [min] 仍强制提示。
class AppUpdatePrompt {
  AppUpdatePrompt._();

  static bool _optionalDismissedThisSession = false;

  static Future<void> checkIfNeeded(
    BuildContext context,
    String backendBaseUrl,
  ) async {
    if (!_isAndroidMobile() && !_isIosMobile()) return;
    final base = backendBaseUrl.trim();
    if (base.isEmpty) return;

    final api = ApiClient(base);
    final cfg = await api.getAppVersionConfig();
    if (!context.mounted || cfg == null || !cfg.success) return;

    final pkg = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    final current = pkg.version.trim();

    final isAndroid = _isAndroidMobile();
    final info = isAndroid ? cfg.android : cfg.ios;
    final storeUrl = _resolveStoreUrl(info);

    final belowMin = isVersionLower(
      current,
      info.minVersion.isEmpty ? null : info.minVersion,
    );
    final belowLatest = info.latestVersion.isNotEmpty &&
        isVersionLower(current, info.latestVersion);

    final apkName = (info.apkFilename?.trim().isNotEmpty ?? false)
        ? info.apkFilename!.trim()
        : kDefaultApkFileName;

    if (belowMin) {
      if (!context.mounted) return;
      final target = info.minVersion.isNotEmpty
          ? info.minVersion
          : info.latestVersion;
      await _showForceDialog(
        context,
        current: current,
        target: target,
        isAndroid: isAndroid,
        backendBaseUrl: base,
        apkFileName: apkName,
        storeUrl: storeUrl,
      );
      return;
    }

    if (belowLatest && !_optionalDismissedThisSession) {
      if (!isAndroid && (storeUrl == null || storeUrl.isEmpty)) {
        return;
      }
      if (!context.mounted) return;
      await _showOptionalDialog(
        context,
        current: current,
        latest: info.latestVersion,
        isAndroid: isAndroid,
        backendBaseUrl: base,
        apkFileName: apkName,
        storeUrl: storeUrl,
      );
    }
  }

  static String? _resolveStoreUrl(AppStoreVersionInfo info) {
    final s = info.storeUrl?.trim() ?? '';
    if (s.isNotEmpty) return s;
    final d = _kIosStoreUrlFromDefine.trim();
    return d.isNotEmpty ? d : null;
  }

  static Future<void> _openUpdateTarget({
    required bool isAndroid,
    required String backendBaseUrl,
    required String apkFileName,
    required String? storeUrl,
  }) async {
    if (isAndroid) {
      final u = _androidApkUriPreferPublic(backendBaseUrl, apkFileName);
      if (u != null && await canLaunchUrl(u)) {
        await launchUrl(u, mode: LaunchMode.externalApplication);
      }
      return;
    }
    final su = storeUrl?.trim() ?? '';
    if (su.isEmpty) return;
    final u = Uri.parse(su);
    if (await canLaunchUrl(u)) {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    }
  }

  static Future<void> _showForceDialog(
    BuildContext context, {
    required String current,
    required String target,
    required bool isAndroid,
    required String backendBaseUrl,
    required String apkFileName,
    required String? storeUrl,
  }) async {
    if (!context.mounted) return;
    final canOpen = isAndroid || (storeUrl != null && storeUrl.isNotEmpty);
    await showDialog<void>(
      context: context,
      barrierDismissible: !canOpen,
      builder: (ctx) => AlertDialog(
        title: const Text('需要更新'),
        content: Text(
          canOpen
              ? (isAndroid
                  ? '当前版本 $current 已低于最低要求 $target，请下载并安装新版本后再使用。'
                  : '当前版本 $current 已低于最低要求 $target，请前往 App Store 更新后再使用。')
              : '当前版本 $current 已低于最低要求 $target。请在 App Store 更新；若链接未配置，请联系管理员设置 HZTECH_APP_IOS_STORE_URL 或编译参数 IOS_APP_STORE_URL。',
        ),
        actions: [
          if (!canOpen)
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('确定'),
            )
          else
            FilledButton(
              onPressed: () async {
                await _openUpdateTarget(
                  isAndroid: isAndroid,
                  backendBaseUrl: backendBaseUrl,
                  apkFileName: apkFileName,
                  storeUrl: storeUrl,
                );
              },
              child: const Text('前往更新'),
            ),
        ],
      ),
    );
  }

  static Future<void> _showOptionalDialog(
    BuildContext context, {
    required String current,
    required String latest,
    required bool isAndroid,
    required String backendBaseUrl,
    required String apkFileName,
    required String? storeUrl,
  }) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: Text(
          isAndroid
              ? '新版本 $latest 已发布（当前 $current），是否下载安装？'
              : '新版本 $latest 已发布（当前 $current），是否前往 App Store？',
        ),
        actions: [
          TextButton(
            onPressed: () {
              _optionalDismissedThisSession = true;
              Navigator.pop(ctx);
            },
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _openUpdateTarget(
                isAndroid: isAndroid,
                backendBaseUrl: backendBaseUrl,
                apkFileName: apkFileName,
                storeUrl: storeUrl,
              );
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }
}
