/// 与 baasapi/server_mgr.py DEFAULT_APK_NAME_RELEASE 及 apk 目录部署一致。
const String kDefaultApkFileName = 'hztech-app-release.apk';

/// 线上 APK 直链基址（`GET /download/apk/...`）。须与 [API_BASE_URL] 同源或 nginx 同样反代 `/download/`。
const String kAwsApkStorageBaseUrl = 'https://www.sfund.now/';

/// 线上 APK 直链（`GET /download/apk/...`，文件部署在 AWS API 机 `apk/`）。
String awsReleaseApkDownloadUrl() {
  final b = kAwsApkStorageBaseUrl.endsWith('/')
      ? kAwsApkStorageBaseUrl
      : '$kAwsApkStorageBaseUrl/';
  return '${b}download/apk/$kDefaultApkFileName';
}
