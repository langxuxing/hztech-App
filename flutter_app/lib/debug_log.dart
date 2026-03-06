// #region agent log
import 'dart:convert';

import 'package:http/http.dart' as http;

void debugLog(String location, String message, Map<String, dynamic> data,
    {String? hypothesisId}) {
  final payload = <String, dynamic>{
    'sessionId': '9089ed',
    'location': location,
    'message': message,
    'data': data,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    if (hypothesisId != null) 'hypothesisId': hypothesisId,
  };
  http
      .post(
        Uri.parse(
            'http://127.0.0.1:7759/ingest/e6327e07-fe57-429c-be6d-c9b352c12dad'),
        headers: {
          'Content-Type': 'application/json',
          'X-Debug-Session-Id': '9089ed',
        },
        body: jsonEncode(payload),
      )
      .catchError((_, __) => Future.value(http.Response('', 500)));
}
// #endregion
