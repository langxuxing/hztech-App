import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../debug_log.dart';
import 'models.dart';

/// 是否为“连接在收到完整响应前关闭”的瞬时错误（可重试）
bool _isConnectionClosedError(Object e, StackTrace s) {
  final msg = e.toString().toLowerCase();
  return msg.contains('connection closed before full header') ||
      msg.contains('connection closed');
}

const _timeout = Duration(seconds: 30);

Future<http.Response> _getWithRetry(Uri uri, Map<String, String> headers) async {
  // #region agent log
  debugLog('client.dart:_getWithRetry', 'request_start', {'uri': uri.toString()},
      hypothesisId: 'H1,H2');
  // #endregion
  try {
    final resp = await http.get(uri, headers: headers).timeout(_timeout);
    // #region agent log
    debugLog('client.dart:_getWithRetry', 'request_ok',
        {'statusCode': resp.statusCode, 'bodyLength': resp.body.length},
        hypothesisId: 'H2,H4');
    // #endregion
    return resp;
  } on Exception catch (e, st) {
    // #region agent log
    debugLog('client.dart:_getWithRetry', 'request_error',
        {'error': e.toString(), 'type': e.runtimeType.toString()},
        hypothesisId: 'H3,H4');
    // #endregion
    if (_isConnectionClosedError(e, st)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return await http.get(uri, headers: headers).timeout(_timeout);
    }
    rethrow;
  }
}

Future<http.Response> _postWithRetry(Uri uri, Map<String, String> headers, {Object? body}) async {
  // #region agent log
  debugLog('client.dart:_postWithRetry', 'request_start', {'uri': uri.toString()},
      hypothesisId: 'H1,H2');
  // #endregion
  try {
    final resp = await http.post(uri, headers: headers, body: body).timeout(_timeout);
    // #region agent log
    debugLog('client.dart:_postWithRetry', 'request_ok',
        {'statusCode': resp.statusCode, 'bodyLength': resp.body.length},
        hypothesisId: 'H2,H4');
    // #endregion
    return resp;
  } on Exception catch (e, st) {
    // #region agent log
    debugLog('client.dart:_postWithRetry', 'request_error',
        {'error': e.toString(), 'type': e.runtimeType.toString()},
        hypothesisId: 'H3,H4');
    // #endregion
    if (_isConnectionClosedError(e, st)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return await http.post(uri, headers: headers, body: body).timeout(_timeout);
    }
    rethrow;
  }
}

class ApiClient {
  ApiClient(this.baseUrl, {this.token});

  final String baseUrl;
  final String? token;

  String get _normalizedBase {
    final b = baseUrl.trim();
    return b.endsWith('/') ? b : '$b/';
  }

  Map<String, String> get _headers {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Connection': 'close',
    };
    if (token != null && token!.isNotEmpty) {
      h['Authorization'] = 'Bearer $token';
    }
    return h;
  }

  Future<AccountProfitResponse> getAccountProfit() async {
    final uri = Uri.parse('${_normalizedBase}api/account-profit');
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return AccountProfitResponse.fromJson(map);
  }

  Future<TradingBotsResponse> getTradingBots({String? status}) async {
    var path = '${_normalizedBase}api/tradingbots';
    if (status != null && status.isNotEmpty) {
      path = '$path?status=$status';
    }
    final uri = Uri.parse(path);
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return TradingBotsResponse.fromJson(map);
  }

  Future<BotOperationResponse> startBot(String botId, {bool force = false}) async {
    final path = '${_normalizedBase}api/tradingbots/$botId/start${force ? '?force=true' : ''}';
    final uri = Uri.parse(path);
    final resp = await _postWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return BotOperationResponse.fromJson(map);
  }

  Future<BotOperationResponse> stopBot(String botId) async {
    final uri = Uri.parse('${_normalizedBase}api/tradingbots/$botId/stop');
    final resp = await _postWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return BotOperationResponse.fromJson(map);
  }

  Future<BotOperationResponse> restartBot(String botId) async {
    final uri = Uri.parse('${_normalizedBase}api/tradingbots/$botId/restart');
    final resp = await _postWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return BotOperationResponse.fromJson(map);
  }
}
