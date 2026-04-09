/// 与 baasapi/server_mgr.py DEFAULT_APK_NAME_RELEASE 及 apk 目录部署一致。
const String kDefaultApkFileName = 'hztech-app-release.apk';

/// AWS 线上 BaasAPI 根地址（与 `dart_defines/production.json` 的 API_BASE_URL、apk 实际存放节点一致）。
const String kAwsApkStorageBaseUrl = 'http://54.66.108.150:9001/';

/// 线上 APK 直链（`GET /download/apk/...`，文件部署在 AWS API 机 `apk/`）。
String awsReleaseApkDownloadUrl() {
  final b = kAwsApkStorageBaseUrl.endsWith('/')
      ? kAwsApkStorageBaseUrl
      : '$kAwsApkStorageBaseUrl/';
  return '${b}download/apk/$kDefaultApkFileName';
}
