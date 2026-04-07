import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Future<String?> readBackendUrl(FlutterSecureStorage storage, String key) {
  throw UnsupportedError('backend_url_persist: no platform implementation');
}

Future<void> writeBackendUrl(
  FlutterSecureStorage storage,
  String key,
  String value,
) {
  throw UnsupportedError('backend_url_persist: no platform implementation');
}
