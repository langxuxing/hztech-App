import 'dart:convert';
import 'dart:io';

/// 将一行 NDJSON 追加到本调试会话日志（仅非 Web、且路径可写时生效）。
Future<void> appendDebugSessionNdjson(String line) async {
  try {
    const path = '/Volumes/HZTech/hztechApp/.cursor/debug-9b3e33.log';
    final f = File(path);
    await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

Future<void> appendDebugSessionNdjsonFromPayload(Map<String, Object?> payload) async {
  await appendDebugSessionNdjson(jsonEncode(payload));
}
