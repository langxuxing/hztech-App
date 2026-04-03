import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../debug_ingest_log.dart';

const _keyToken = 'auth_token';
const _keyBackendUrl = 'backend_url';
const _keyFingerprint = 'fingerprint_enabled';
const _keyUnlockedUntil = 'unlocked_until_ms';

/// 编译期注入后端基址（打包时区分环境）：
/// `flutter build apk --dart-define=API_BASE_URL=http://192.168.1.10:8080/`
/// 或 `flutter build apk --dart-define-from-file=dart_defines/local.json`（在 flutter_app 目录下执行时路径为 dart_defines/...）
const String _kCompileTimeApiBase = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

/// 未使用 [API_BASE_URL] 时的线上默认（与 deploy-aws.json 中 API 主机一致）
const String _kDefaultProductionApiBase = 'http://54.66.108.150:9000/';

/// 未使用 [API_BASE_URL] 时的本地调试默认（单进程 `run_local.sh` 默认端口 8080）
const String _kDefaultDebugApiBase = 'http://127.0.0.1:8080/';

String _normalizeBackendBaseUrl(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return t;
  final u = t.startsWith('http') ? t : 'http://$t';
  return u.endsWith('/') ? u : '$u/';
}

/// 历史本地默认端口为 9000，当前 `run_local.sh` 为 8080；已保存的旧地址自动升级，避免登录仍连 9000。
String? _migrateLocal9000To8080(String normalizedUrl) {
  final t = normalizedUrl.trim();
  if (t.isEmpty) return null;
  Uri uri;
  try {
    uri = Uri.parse(t);
  } catch (_) {
    return null;
  }
  if (!uri.hasPort || uri.port != 9000) return null;
  final h = uri.host.toLowerCase();
  if (h != '127.0.0.1' && h != 'localhost') return null;
  return uri.replace(port: 8080).toString();
}

/// 本机 `127.0.0.1` / `localhost` 端口 9000 → 8080。登录框与存储共用；含字符串兜底，避免 Web 上 Uri 与迁移未命中时仍请求 :9000。
String migrateLocalBackendPort9000To8080(String raw) {
  final normalized = _normalizeBackendBaseUrl(raw);
  if (normalized.isEmpty) return normalized;
  final viaUri = _migrateLocal9000To8080(normalized);
  if (viaUri != null) {
    final next = _normalizeBackendBaseUrl(viaUri);
    if (next != normalized) return next;
  }
  var s = normalized;
  if (s.contains('127.0.0.1:9000')) {
    s = s.replaceAll('127.0.0.1:9000', '127.0.0.1:8080');
  }
  if (s.contains('localhost:9000')) {
    s = s.replaceAll('localhost:9000', 'localhost:8080');
  }
  return _normalizeBackendBaseUrl(s);
}

/// 安装后首次打开时的默认后端基址（用户可在设置里修改并持久化）。
///
/// 优先级：编译期 `API_BASE_URL` > Debug 用本机 > Release 用线上默认。
/// 真机连本机请用 `--dart-define=API_BASE_URL=http://<电脑局域网IP>:8080/`；
/// Android 模拟器连本机可用 `http://10.0.2.2:8080/`。
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
  SecurePrefs() : _storage = const FlutterSecureStorage(aOptions: androidOptions);

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

  Future<String> get backendBaseUrl async {
    final v = await _storage.read(key: _keyBackendUrl);
    final raw = v ?? defaultBackendUrl;
    final normalized = _normalizeBackendBaseUrl(raw);
    final next = migrateLocalBackendPort9000To8080(raw);
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
          message: 'migrated_9000_to_8080',
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
    await _storage.delete(key: _keyUnlockedUntil);
  }
}
