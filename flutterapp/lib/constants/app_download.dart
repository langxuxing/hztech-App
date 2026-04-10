/// 与 baasapi/server_mgr.py DEFAULT_APK_NAME_RELEASE 及 apk 目录部署一致。
const String kDefaultApkFileName = 'hztech-app-release.apk';

/// 线上 APK 直链基址。路径使用 `api/download/apk/...`，适配 nginx 仅将 `/api/` 反代到后端的情形。
const String kAwsApkStorageBaseUrl = 'https://www.sfund.now/';

/// 线上 APK 直链（`GET /api/download/apk/...`；直连后端时 `/download/apk/` 仍可用）。
String awsReleaseApkDownloadUrl() {
  return androidApkDownloadUrlForFileName(kDefaultApkFileName);
}

/// 与 [kAwsApkStorageBaseUrl] 拼接的 APK 直链（与 `/api/app-version` 的 `apk_filename` 一致）。
String androidApkDownloadUrlForFileName(String fileName) {
  final name = fileName.trim().isEmpty ? kDefaultApkFileName : fileName.trim();
  final b = kAwsApkStorageBaseUrl.endsWith('/')
      ? kAwsApkStorageBaseUrl
      : '$kAwsApkStorageBaseUrl/';
  return '${b}api/download/apk/${Uri.encodeComponent(name)}';
}
