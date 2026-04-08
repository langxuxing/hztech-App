import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web/web.dart';

/// Web：后端基址非高敏信息；避免 `flutter_secure_storage_web` 依赖
/// `window.crypto` / 加密密钥环在部分环境下触发 `!` 空断言失败。
Future<String?> readBackendUrl(FlutterSecureStorage? _, String key) async =>
    window.localStorage.getItem(key);

Future<void> writeBackendUrl(
  FlutterSecureStorage? _,
  String key,
  String value,
) async {
  window.localStorage.setItem(key, value);
}
