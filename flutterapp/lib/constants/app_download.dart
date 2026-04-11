/// 与 baasapi/server_mgr.py DEFAULT_APK_NAME_RELEASE 及 apk 目录部署一致。
const String kDefaultApkFileName = 'hztech-app-release.apk';

/// 编译期覆盖 APK 直链基址（不经主站 nginx）。
/// 例：`flutter build apk --dart-define=HZTECH_APK_BASE_URL=http://54.252.181.151:9000/`
const String _kApkBaseFromEnv = String.fromEnvironment(
  'HZTECH_APK_BASE_URL',
  defaultValue: '',
);

/// 与 `baasapi/deploy-aws.json` 中 BaasAPI 段一致：`main.py` 提供 `GET /download/apk/<文件名>.apk`
///（另保留 `GET /api/download/apk/...` 供仅反代 `/api/` 的 nginx 兼容）。
/// 双机若未向该机同步 apk/，请用 [HZTECH_APK_BASE_URL] 指到实际放 APK 的主机。
const String _kDefaultApkDirectBaseUrl = 'http://54.66.108.150:9001/';

/// 与 BaasAPI / `serve_web_static` 统一的短路径（无 `/api/` 前缀）。
const String kApkDownloadUrlPath = 'download/apk';

/// 线上 APK 直链基址（仅站点根；完整 URL 为 `[基址]download/apk/<文件名>.apk`）。
///
/// 与登录/API 用的站点根（如 https://www.sfund.now/）可不同：此处仅用于 APK 直链。
String get kAwsApkStorageBaseUrl {
  final raw = _kApkBaseFromEnv.trim();
  if (raw.isEmpty) {
    return _kDefaultApkDirectBaseUrl;
  }
  final u = raw.startsWith('http') ? raw : 'http://$raw';
  return u.endsWith('/') ? u : '$u/';
}

/// 线上 APK 直链（`GET /download/apk/<文件名>.apk`）。
String awsReleaseApkDownloadUrl() {
  return androidApkDownloadUrlForFileName(kDefaultApkFileName);
}

/// 与 [kAwsApkStorageBaseUrl] 拼接的 APK 直链（与 `/api/app-version` 的 `apk_filename` 一致）。
String androidApkDownloadUrlForFileName(String fileName) {
  final name = fileName.trim().isEmpty ? kDefaultApkFileName : fileName.trim();
  final b = kAwsApkStorageBaseUrl;
  final base = b.endsWith('/') ? b : '$b/';
  return '$base$kApkDownloadUrlPath/${Uri.encodeComponent(name)}';
}
