import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

Future<http.Response> _getWithRetry(
  Uri uri,
  Map<String, String> headers,
) async {
  // #region agent log
  debugLog('client.dart:_getWithRetry', 'request_start', {
    'uri': uri.toString(),
  }, hypothesisId: 'H1,H2');
  // #endregion
  try {
    final resp = await http.get(uri, headers: headers).timeout(_timeout);
    // #region agent log
    debugLog('client.dart:_getWithRetry', 'request_ok', {
      'statusCode': resp.statusCode,
      'bodyLength': resp.body.length,
    }, hypothesisId: 'H2,H4');
    // #endregion
    return resp;
  } on Exception catch (e, st) {
    // #region agent log
    debugLog('client.dart:_getWithRetry', 'request_error', {
      'error': e.toString(),
      'type': e.runtimeType.toString(),
    }, hypothesisId: 'H3,H4');
    // #endregion
    if (_isConnectionClosedError(e, st)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return await http.get(uri, headers: headers).timeout(_timeout);
    }
    rethrow;
  }
}

Future<http.Response> _postWithRetry(
  Uri uri,
  Map<String, String> headers, {
  Object? body,
}) async {
  // #region agent log
  debugLog('client.dart:_postWithRetry', 'request_start', {
    'uri': uri.toString(),
  }, hypothesisId: 'H1,H2');
  // #endregion
  try {
    final resp = await http
        .post(uri, headers: headers, body: body)
        .timeout(_timeout);
    // #region agent log
    debugLog('client.dart:_postWithRetry', 'request_ok', {
      'statusCode': resp.statusCode,
      'bodyLength': resp.body.length,
    }, hypothesisId: 'H2,H4');
    // #endregion
    return resp;
  } on Exception catch (e, st) {
    // #region agent log
    debugLog('client.dart:_postWithRetry', 'request_error', {
      'error': e.toString(),
      'type': e.runtimeType.toString(),
    }, hypothesisId: 'H3,H4');
    // #endregion
    if (_isConnectionClosedError(e, st)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return await http
          .post(uri, headers: headers, body: body)
          .timeout(_timeout);
    }
    rethrow;
  }
}

class ApiClient {
  ApiClient(this.baseUrl, {this.token});

  /// 持仓分段调试开关：设为 true 时在 Debug 构建下打印 [持仓-界面] 的 API 调用与返回（仅控制台）
  static bool debugPositions = false;

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

  /// POST /api/login，返回 success、token、message（401 时 success=false）
  Future<LoginResponse> login(String username, String password) async {
    final uri = Uri.parse('${_normalizedBase}api/login');
    final body = jsonEncode({
      'username': username,
      'password': password,
    });
    final resp = await _postWithRetry(uri, _headers, body: body);
    final raw = resp.body.trim();
    if (raw.isEmpty) {
      throw FormatException('后端返回空内容，请检查后端地址是否为 API 服务（如 http://localhost:9001/）');
    }
    if (raw.toLowerCase().startsWith('<')) {
      throw FormatException(
        '后端返回了网页而非接口数据。请将「后端地址」改为 API 地址（如 http://localhost:9001/），不要填前端页面地址（如 62567）。',
      );
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return LoginResponse.fromJson(map);
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

  Future<BotOperationResponse> startBot(
    String botId, {
    bool force = false,
  }) async {
    final path =
        '${_normalizedBase}api/tradingbots/$botId/start${force ? '?force=true' : ''}';
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

  Future<BotProfitHistoryResponse> getBotProfitHistory(
    String botId, {
    int limit = 500,
  }) async {
    final uri = Uri.parse(
      '${_normalizedBase}api/tradingbots/$botId/profit-history?limit=$limit',
    );
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return BotProfitHistoryResponse.fromJson(map);
  }

  Future<OkxPositionsResponse> getOkxPositions() async {
    final uri = Uri.parse('${_normalizedBase}api/okx/positions');
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return OkxPositionsResponse.fromJson(map);
  }

  /// 指定 bot 的持仓（数量、持仓成本、当前价、动态盈亏）
  Future<OkxPositionsResponse> getTradingbotPositions(String botId) async {
    if (kDebugMode && ApiClient.debugPositions) {
      // ignore: avoid_print
      print('[持仓-界面] 调用 server API: GET api/tradingbots/$botId/positions');
    }
    final uri = Uri.parse('${_normalizedBase}api/tradingbots/$botId/positions');
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final result = OkxPositionsResponse.fromJson(map);
    if (kDebugMode && ApiClient.debugPositions) {
      // ignore: avoid_print
      print('[持仓-界面] server 返回: statusCode=${resp.statusCode}, positions 数量=${result.positions.length}');
    }
    return result;
  }

  Future<TradingbotSeasonsResponse> getTradingbotSeasons(
    String botId, {
    int limit = 50,
  }) async {
    final uri = Uri.parse(
      '${_normalizedBase}api/tradingbots/$botId/seasons?limit=$limit',
    );
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return TradingbotSeasonsResponse.fromJson(map);
  }
}
