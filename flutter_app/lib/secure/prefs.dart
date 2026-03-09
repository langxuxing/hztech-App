import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../debug_log.dart';

const _keyToken = 'auth_token';
const _keyBackendUrl = 'backend_url';
const _keyFingerprint = 'fingerprint_enabled';
const _keyUnlockedUntil = 'unlocked_until_ms';

/// Web 开发模式（localhost）下默认连本地 API，否则连 AWS
String get defaultBackendUrl =>
    (kIsWeb && kDebugMode) ? 'http://localhost:9001/' : 'http://54.66.108.150:9001/';
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
    // #region agent log
    final v = await _storage.read(key: _keyBackendUrl);
    final result = v ?? defaultBackendUrl;
    debugLog('prefs.dart:backendBaseUrl', 'backendBaseUrl read',
        {'storageValue': v, 'returned': result}, hypothesisId: 'H1,H5');
    return result;
    // #endregion
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
