import 'package:web/web.dart';

Future<String?> webPrefsRead(String key) async => window.localStorage.getItem(key);

Future<void> webPrefsWrite(String key, String? value) async {
  if (value == null || value.isEmpty) {
    window.localStorage.removeItem(key);
  } else {
    window.localStorage.setItem(key, value);
  }
}

Future<void> webPrefsDelete(String key) async {
  window.localStorage.removeItem(key);
}
