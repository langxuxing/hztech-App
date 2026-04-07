import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/app_user_role.dart';
import '../debug_ingest_log.dart';

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

/// 未使用 [API_BASE_URL] 时的线上默认（与 deploy-aws.json `baas_api` 主机及 `baas_api_port` 一致）
const String _kDefaultProductionApiBase = 'http://54.66.108.150:9001/';

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
String migrateLegacyBackendApiPort(String raw) {
  final normalized = _normalizeBackendBaseUrl(raw);
  if (normalized.isEmpty) return normalized;
  Uri uri;
  try {
    uri = Uri.parse(normalized);
  } catch (_) {
    return _migrateLegacyBackendApiPortStringFallback(normalized);
  }
  if (!uri.hasPort) return normalized;
  final h = uri.host.toLowerCase();
  final p = uri.port;
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
    MapEntry('54.66.108.150:9000', '54.66.108.150:9001'),
    MapEntry('54.252.181.151:9000', '54.252.181.151:9001'),
  ]) {
    s = s.replaceAll(entry.key, entry.value);
  }
  return _normalizeBackendBaseUrl(s);
}

/// 安装后首次打开时的默认后端基址（用户可在设置里修改并持久化）。
///
/// 优先级：编译期 `API_BASE_URL` > Debug 构建默认本机 > 非 Debug（Release/Profile）默认 AWS。
/// 真机连本机请用 `--dart-define=API_BASE_URL=http://<电脑局域网IP>:9001/`；
/// Android 模拟器连本机可用 `http://10.0.2.2:9001/`。
String get defaultBackendUrl {
  if (_kCompileTimeApiBase.trim().isNotEmpty) {
    return _normalizeBackendBaseUrl(_kCompileTimeApiBase);
  }
  if (kDebugMode) {
    return _kDefaultDebugApiBase;
  }
  return _kDefaultProductionApiBase;
}
const unlockDurationMs = 5 * 60 * 1000; // 5 分钟

class SecurePrefs {
  SecurePrefs()
      : _storage = FlutterSecureStorage(
          aOptions: androidOptions,
          // macOS 沙盒：默认 useDataProtectionKeyChain 易触发 -34018（钥匙串 entitlement）
          mOptions: (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS)
              ? const MacOsOptions(useDataProtectionKeyChain: false)
              : MacOsOptions.defaultOptions,
        );

  static const androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  final FlutterSecureStorage _storage;

  Future<String?> get authToken => _storage.read(key: _keyToken);
  Future<void> setAuthToken(String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: _keyToken);
    } else {
      await _storage.write(key: _keyToken, value: value);
    }
  }

  /// 登录或 GET /api/me 后写入，与后端 role 一致。
  Future<void> setUserRole(String? role) async {
    if (role == null || role.isEmpty) {
      await _storage.delete(key: _keyUserRole);
    } else {
      await _storage.write(key: _keyUserRole, value: role.trim().toLowerCase());
    }
  }

  Future<AppUserRole> getAppUserRole() async {
    final v = await _storage.read(key: _keyUserRole);
    return AppUserRole.fromApi(v);
  }

  Future<String> get backendBaseUrl async {
    final v = await _storage.read(key: _keyBackendUrl);
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
          data: <String, Object?>{
            'next': next,
            'normalizedBefore': normalized,
          },
        ),
      );
      // #endregion
      await _storage.write(key: _keyBackendUrl, value: next);
    }
    return next;
  }

  Future<void> setBackendBaseUrl(String value) async {
    final normalized = value.trim();
    final url = normalized.isEmpty
        ? defaultBackendUrl
        : (normalized.startsWith('http') ? normalized : 'http://$normalized');
    await _storage.write(key: _keyBackendUrl, value: url.endsWith('/') ? url : '$url/');
  }

  Future<bool> get fingerprintEnabled async {
    final v = await _storage.read(key: _keyFingerprint);
    return v == 'true';
  }

  Future<void> setFingerprintEnabled(bool value) async {
    await _storage.write(key: _keyFingerprint, value: value.toString());
  }

  Future<int> get _unlockedUntilMs async {
    final v = await _storage.read(key: _keyUnlockedUntil);
    return int.tryParse(v ?? '') ?? 0;
  }

  Future<void> setUnlockedUntilMs(int value) async {
    await _storage.write(key: _keyUnlockedUntil, value: value.toString());
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
    await _storage.delete(key: _keyToken);
    await _storage.delete(key: _keyUserRole);
    await _storage.delete(key: _keyUnlockedUntil);
  }
}
