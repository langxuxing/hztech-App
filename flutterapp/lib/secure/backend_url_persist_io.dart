import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Future<String?> readBackendUrl(FlutterSecureStorage storage, String key) =>
    storage.read(key: key);

Future<void> writeBackendUrl(
  FlutterSecureStorage storage,
  String key,
  String value,
) =>
    storage.write(key: key, value: value);
