// #region agent log
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'debug_ingest_log_io.dart'
    if (dart.library.html) 'debug_ingest_log_stub.dart' as ingest_io;

/// 调试会话 9b3e33：向本地 ingest 上报 NDJSON（Web 无 dart:io 写文件）
Future<void> debugIngestLog({
  required String location,
  required String message,
  required Map<String, Object?> data,
  required String hypothesisId,
  String runId = 'baseline',
}) async {
  final payload = <String, Object?>{
    'sessionId': '9b3e33',
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'location': location,
    'message': message,
    'data': data,
    'hypothesisId': hypothesisId,
    'runId': runId,
  };
  unawaited(ingest_io.appendDebugSessionNdjsonFromPayload(payload));
  try {
    await http
        .post(
          Uri.parse(
            'http://127.0.0.1:7293/ingest/4067d007-374f-4ae3-8716-ed65822af179',
          ),
          headers: {
            'Content-Type': 'application/json',
            'X-Debug-Session-Id': '9b3e33',
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 3));
  } catch (_) {}
  debugPrint('[9b3e33] $location $message ${jsonEncode(data)}');
}

// #endregion
