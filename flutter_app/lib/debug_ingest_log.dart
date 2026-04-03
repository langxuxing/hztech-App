// #region agent log
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 调试会话 cad3d8：向本地 ingest 上报 NDJSON（Web 无 dart:io 写文件）
Future<void> debugIngestLog({
  required String location,
  required String message,
  required Map<String, Object?> data,
  required String hypothesisId,
}) async {
  final payload = <String, Object?>{
    'sessionId': 'cad3d8',
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'location': location,
    'message': message,
    'data': data,
    'hypothesisId': hypothesisId,
  };
  try {
    await http
        .post(
          Uri.parse(
            'http://127.0.0.1:7394/ingest/25f78303-fa18-4b2e-9d57-baec5e20262a',
          ),
          headers: {
            'Content-Type': 'application/json',
            'X-Debug-Session-Id': 'cad3d8',
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 3));
  } catch (_) {}
  debugPrint('[cad3d8] $location $message ${jsonEncode(data)}');
}
// #endregion
