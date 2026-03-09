// #region agent log
import 'dart:convert';

import 'package:http/http.dart' as http;

void debugLog(String location, String message, Map<String, dynamic> data,
    {String? hypothesisId}) {
  final payload = <String, dynamic>{
    'sessionId': '977bbd',
    'location': location,
    'message': message,
    'data': data,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    if (hypothesisId != null) 'hypothesisId': hypothesisId,
  };
  http
      .post(
        Uri.parse(
            'http://127.0.0.1:7612/ingest/4067d007-374f-4ae3-8716-ed65822af179'),
        headers: {
          'Content-Type': 'application/json',
          'X-Debug-Session-Id': '977bbd',
        },
        body: jsonEncode(payload),
      )
      .catchError((_, __) => Future.value(http.Response('', 500)));
}
// #endregion
