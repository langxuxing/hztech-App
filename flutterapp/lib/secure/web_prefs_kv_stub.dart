/// 非 Web 编译目标占位（仅 Web 会调用 [webPrefsRead] 等）。
Future<String?> webPrefsRead(String key) async => null;

Future<void> webPrefsWrite(String key, String? value) async {}

Future<void> webPrefsDelete(String key) async {}
