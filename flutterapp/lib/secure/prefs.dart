import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/app_user_role.dart';
import '../debug_ingest_log.dart';
import 'backend_url_persist.dart';
import 'web_prefs_kv.dart';

const _keyToken = 'auth_token';
const _keyUserRole = 'user_role';
const _keyBackendUrl = 'backend_url';
const _keyFingerprint = 'fingerprint_enabled';
const _keyUnlockedUntil = 'unlocked_until_ms';

/// 编译期注入后端基址（打包时区分环境）：
/// `flutter build apk --dart-define=API_BASE_URL=http://192.168.1.10:9001/`
/// 或 `flutter build apk --dart-define-from-file=dart_defines/local.json`（在 flutterapp 目录下执行时路径为 dart_defines/...）
///
/// **与构建模式的关系（未注入 [API_BASE_URL] 时）**
/// - `flutter build apk --debug` / `flutter run`：`kDebugMode` 为 true，安装后首次默认本机 [ _kDefaultDebugApiBase ]。
/// - `flutter build apk --release` / `flutter build web`：`kDebugMode` 为 false，默认 AWS [ _kDefaultProductionApiBase ]。
/// - Profile 构建与 Release 相同，默认走线上。
/// - `baasapi/server_mgr.py build` / `build-web` 与 `deploy2AWS.sh` 会为 release 传入 `dart_defines/production.json`，与线上默认一致。
const String _kCompileTimeApiBase = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

/// 与 deploy-aws.json `web_https_api_base_url` 一致，由 server_mgr 构建 Web 时注入。
/// 在 **https** 页面打开 Web 端时优先于 [API_BASE_URL]，避免浏览器混合内容拦截（https 页请求 http API）。
const String _kWebHttpsApiBase = String.fromEnvironment(
  'WEB_HTTPS_API_BASE_URL',
  defaultValue: '',
);

/// 未使用 [API_BASE_URL] 时的线上默认（经 nginx `www.sfund.now/api/` → BaasAPI）
const String _kDefaultProductionApiBase = 'https://www.sfund.now/';

/// 未使用 [API_BASE_URL] 时的本地调试默认（API 服务端口；Flutter Web 页面由 serve_web_static 等单独端口提供）
const String _kDefaultDebugApiBase = 'http://127.0.0.1:9001/';

String _normalizeBackendBaseUrl(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return t;
  final u = t.startsWith('http') ? t : 'http://$t';
  return u.endsWith('/') ? u : '$u/';
}

bool _isLocalDevHost(String host) {
  final h = host.toLowerCase();
  return h == '127.0.0.1' ||
      h == 'localhost' ||
      h == '10.0.2.2' ||
      h.startsWith('192.168.');
}

bool _isAwsPresetHost(String host) {
  final h = host.toLowerCase();
  return h == '54.66.108.150' || h == '54.252.181.151';
}

/// 将历史保存的「Web 口 / 旧 API 口」迁到当前约定的 API 口 9001（本机与局域网 8080/9000；AWS 旧默认 9000）。
/// 在 **https** 站点上打开 Web 时，将已保存的公网 **http** API 升为 [WEB_HTTPS_API_BASE_URL]，避免混合内容拦截。
String _webHttpsUpgradeIfNeeded(String normalized) {
  if (!kIsWeb || _kWebHttpsApiBase.trim().isEmpty) return normalized;
  if (Uri.base.scheme.toLowerCase() != 'https') return normalized;
  Uri u;
  try {
    u = Uri.parse(normalized);
  } catch (_) {
    return normalized;
  }
  if (u.scheme.toLowerCase() != 'http') return normalized;
  final h = u.host.toLowerCase();
  if (_isLocalDevHost(h)) return normalized;
  return _normalizeBackendBaseUrl(_kWebHttpsApiBase);
}

String migrateLegacyBackendApiPort(String raw) {
  final normalized = _normalizeBackendBaseUrl(raw);
  if (normalized.isEmpty) return normalized;
  Uri uri;
  try {
    uri = Uri.parse(normalized);
  } catch (_) {
    return _migrateLegacyBackendApiPortStringFallback(normalized);
  }
  // 误将 nginx 的 /api 前缀写进基址会导致 /api/api/login；统一升为站点根。
  final pathNoTrailSlash = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (pathNoTrailSlash == '/api') {
    return _normalizeBackendBaseUrl(uri.resolve('/').toString());
  }
  if (!uri.hasPort) return normalized;
  final h = uri.host.toLowerCase();
  final p = uri.port;
  // Web 机 54.252.181.151:9000 为静态页；线上 API 经 nginx → https://www.sfund.now/api/
  if (h == '54.252.181.151' && p == 9000) {
    return _normalizeBackendBaseUrl('https://www.sfund.now/');
  }
  if (h == '54.66.108.150' && p == 9001) {
    return _normalizeBackendBaseUrl('https://www.sfund.now/');
  }
  int? newPort;
  if (_isLocalDevHost(h) && (p == 8080 || p == 9000)) {
    newPort = 9001;
  } else if (_isAwsPresetHost(h) && p == 9000) {
    newPort = 9001;
  }
  if (newPort == null) return normalized;
  final next = _normalizeBackendBaseUrl(uri.replace(port: newPort).toString());
  return next == normalized ? normalized : next;
}

String _migrateLegacyBackendApiPortStringFallback(String normalized) {
  var s = normalized;
  for (final entry in <MapEntry<String, String>>[
    MapEntry('127.0.0.1:8080', '127.0.0.1:9001'),
    MapEntry('127.0.0.1:9000', '127.0.0.1:9001'),
    MapEntry('localhost:8080', 'localhost:9001'),
    MapEntry('localhost:9000', 'localhost:9001'),
    MapEntry('http://54.66.108.150:9000/', 'https://www.sfund.now/'),
    MapEntry('http://54.66.108.150:9000', 'https://www.sfund.now/'),
    MapEntry('http://54.252.181.151:9000/', 'https://www.sfund.now/'),
    MapEntry('http://54.252.181.151:9000', 'https://www.sfund.now/'),
    MapEntry('http://54.66.108.150:9001/', 'https://www.sfund.now/'),
    MapEntry('http://54.66.108.150:9001', 'https://www.sfund.now/'),
  ]) {
    s = s.replaceAll(entry.key, entry.value);
  }
  return _normalizeBackendBaseUrl(s);
}

/// 安装后首次打开时的默认后端基址（用户可在设置里修改并持久化）。
///
/// 优先级：Debug → 本机；Web 且当前页为 **https** 且已注入 `WEB_HTTPS_API_BASE_URL` → 该 HTTPS API（避免混合内容）；
/// 否则编译期 `API_BASE_URL`；否则非 Debug 默认 AWS HTTP。
/// 真机连本机请用 `--dart-define=API_BASE_URL=http://<电脑局域网IP>:9001/`；
/// Android 模拟器连本机可用 `http://10.0.2.2:9001/`。
String get defaultBackendUrl {
  if (kDebugMode) {
    return _kDefaultDebugApiBase;
  }
  if (kIsWeb &&
      _kWebHttpsApiBase.trim().isNotEmpty &&
      Uri.base.scheme.toLowerCase() == 'https') {
    return _normalizeBackendBaseUrl(_kWebHttpsApiBase);
  }
  if (_kCompileTimeApiBase.trim().isNotEmpty) {
    return _normalizeBackendBaseUrl(_kCompileTimeApiBase);
  }
  return _kDefaultProductionApiBase;
}

const unlockDurationMs = 5 * 60 * 1000; // 5 分钟

class SecurePrefs {
  SecurePrefs()
    : _storage = kIsWeb
        ? null
        : FlutterSecureStorage(
            aOptions: androidOptions,
            // macOS 沙盒：默认 useDataProtectionKeyChain 易触发 -34018（钥匙串 entitlement）
            mOptions: (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS)
                ? const MacOsOptions(useDataProtectionKeyChain: false)
                : MacOsOptions.defaultOptions,
          );

  static const androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  /// Web 端不使用：[`flutter_secure_storage_web`] 在部分浏览器/隐私设置下会因
  /// `window.crypto` 等触发 `!` 空断言；登录态等改走 [localStorage]（见 [web_prefs_kv_web.dart]）。
  final FlutterSecureStorage? _storage;

  Future<String?> get authToken async {
    if (kIsWeb) return webPrefsRead(_keyToken);
    return _storage!.read(key: _keyToken);
  }

  Future<void> setAuthToken(String? value) async {
    if (kIsWeb) {
      await webPrefsWrite(_keyToken, value);
      return;
    }
    if (value == null || value.isEmpty) {
      await _storage!.delete(key: _keyToken);
    } else {
      await _storage!.write(key: _keyToken, value: value);
    }
  }

  /// 登录或 GET /api/me 后写入，与后端 role 一致。
  Future<void> setUserRole(String? role) async {
    if (kIsWeb) {
      await webPrefsWrite(
        _keyUserRole,
        role != null && role.isNotEmpty ? role.trim().toLowerCase() : null,
      );
      return;
    }
    if (role == null || role.isEmpty) {
      await _storage!.delete(key: _keyUserRole);
    } else {
      await _storage!.write(key: _keyUserRole, value: role.trim().toLowerCase());
    }
  }

  Future<AppUserRole> getAppUserRole() async {
    final v = kIsWeb
        ? await webPrefsRead(_keyUserRole)
        : await _storage!.read(key: _keyUserRole);
    return AppUserRole.fromApi(v);
  }

  Future<String> get backendBaseUrl async {
    final v = await readBackendUrl(_storage, _keyBackendUrl);
    final raw = v ?? defaultBackendUrl;
    final normalized = _normalizeBackendBaseUrl(raw);
    final next = migrateLegacyBackendApiPort(raw);
    // #region agent log
    Uri? pu;
    try {
      pu = Uri.parse(normalized);
    } catch (_) {}
    unawaited(
      debugIngestLog(
        location: 'prefs.dart:backendBaseUrl',
        message: 'resolve_backend_url',
        hypothesisId: 'H1_H2_H3',
        data: <String, Object?>{
          'storedRaw': v,
          'compileTimeApiBaseEmpty': _kCompileTimeApiBase.trim().isEmpty,
          'compileTimeApiBaseLen': _kCompileTimeApiBase.length,
          'kDebugMode': kDebugMode,
          'kReleaseMode': kReleaseMode,
          'defaultBackendUrl': defaultBackendUrl,
          'raw': raw,
          'normalized': normalized,
          'migratedNext': next,
          'uriHasPort': pu?.hasPort,
          'uriPort': pu?.port,
          'uriHost': pu?.host,
        },
      ),
    );
    // #endregion
    if (next != normalized) {
      // #region agent log
      unawaited(
        debugIngestLog(
          location: 'prefs.dart:backendBaseUrl',
          message: 'migrated_legacy_api_port',
          hypothesisId: 'H1',
          data: <String, Object?>{'next': next, 'normalizedBefore': normalized},
        ),
      );
      // #endregion
      await writeBackendUrl(_storage, _keyBackendUrl, next);
    }
    final upgraded = _webHttpsUpgradeIfNeeded(next);
    if (upgraded != next) {
      await writeBackendUrl(_storage, _keyBackendUrl, upgraded);
      return upgraded;
    }
    return next;
  }

  Future<void> setBackendBaseUrl(String value) async {
    final normalized = value.trim();
    final url = normalized.isEmpty
        ? defaultBackendUrl
        : (normalized.startsWith('http') ? normalized : 'http://$normalized');
    await writeBackendUrl(
      _storage,
      _keyBackendUrl,
      url.endsWith('/') ? url : '$url/',
    );
  }

  Future<bool> get fingerprintEnabled async {
    final v = kIsWeb
        ? await webPrefsRead(_keyFingerprint)
        : await _storage!.read(key: _keyFingerprint);
    return v == 'true';
  }

  Future<void> setFingerprintEnabled(bool value) async {
    if (kIsWeb) {
      await webPrefsWrite(_keyFingerprint, value.toString());
      return;
    }
    await _storage!.write(key: _keyFingerprint, value: value.toString());
  }

  Future<int> get _unlockedUntilMs async {
    final v = kIsWeb
        ? await webPrefsRead(_keyUnlockedUntil)
        : await _storage!.read(key: _keyUnlockedUntil);
    return int.tryParse(v ?? '') ?? 0;
  }

  Future<void> setUnlockedUntilMs(int value) async {
    if (kIsWeb) {
      await webPrefsWrite(_keyUnlockedUntil, value.toString());
      return;
    }
    await _storage!.write(key: _keyUnlockedUntil, value: value.toString());
  }

  Future<bool> get isUnlocked async {
    final until = await _unlockedUntilMs;
    return until > DateTime.now().millisecondsSinceEpoch;
  }

  Future<bool> get isLoggedIn async {
    final t = await authToken;
    return t != null && t.isNotEmpty;
  }

  Future<void> clearOnLogout() async {
    if (kIsWeb) {
      await webPrefsDelete(_keyToken);
      await webPrefsDelete(_keyUserRole);
      await webPrefsDelete(_keyUnlockedUntil);
      return;
    }
    final storage = _storage;
    if (storage == null) return;
    await storage.delete(key: _keyToken);
    await storage.delete(key: _keyUserRole);
    await storage.delete(key: _keyUnlockedUntil);
  }
}
