import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../debug_ingest_log.dart';
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
  try {
    final resp = await http.get(uri, headers: headers).timeout(_timeout);
    return resp;
  } on Exception catch (e, st) {
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
  try {
    final resp = await http
        .post(uri, headers: headers, body: body)
        .timeout(_timeout);
    return resp;
  } on Exception catch (e, st) {
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
    // #region agent log
    unawaited(
      debugIngestLog(
        location: 'client.dart:login',
        message: 'login_request_uri',
        hypothesisId: 'H5',
        data: <String, Object?>{
          'baseUrl': baseUrl,
          'normalizedBase': _normalizedBase,
          'loginUri': uri.toString(),
        },
      ),
    );
    // #endregion
    final body = jsonEncode({
      'username': username,
      'password': password,
    });
    final resp = await _postWithRetry(uri, _headers, body: body);
    final raw = resp.body.trim();
    if (raw.isEmpty) {
      throw FormatException('后端返回空内容，请检查后端地址是否为 API 服务（如 http://localhost:8080/）');
    }
    if (raw.toLowerCase().startsWith('<')) {
      throw FormatException(
        '后端返回了网页而非接口数据。请将「后端地址」改为服务根地址（如 http://localhost:8080/），路径为 /api/...；不要填错误端口。',
      );
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return LoginResponse.fromJson(map);
  }

  Future<MeResponse> getMe() async {
    final uri = Uri.parse('${_normalizedBase}api/me');
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return MeResponse.fromJson(map);
  }

  Future<List<ManagedUserRow>> getUsersList() async {
    final uri = Uri.parse('${_normalizedBase}api/users');
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    if (map['success'] != true) {
      throw StateError(map['message']?.toString() ?? 'users failed');
    }
    final raw = map['users'] as List<dynamic>? ?? [];
    return raw
        .map((e) => ManagedUserRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 失败时抛出 [StateError]，[StateError.message] 为服务端文案（若有）。
  Future<ManagedUserRow> patchUser(
    int userId, {
    String? role,
    List<String>? linkedAccountIds,
  }) async {
    final uri = Uri.parse('${_normalizedBase}api/users/$userId');
    final body = <String, dynamic>{};
    if (role != null) body['role'] = role;
    if (linkedAccountIds != null) body['linked_account_ids'] = linkedAccountIds;
    final resp =
        await http.patch(uri, headers: _headers, body: jsonEncode(body)).timeout(_timeout);
    return _parsePatchUserRequired(resp);
  }

  /// POST /api/users（仅管理员）
  Future<ManagedUserRow?> createUser({
    required String username,
    required String password,
    String role = 'trader',
    List<String>? linkedAccountIds,
  }) async {
    final uri = Uri.parse('${_normalizedBase}api/users');
    final body = <String, dynamic>{
      'username': username,
      'password': password,
      'role': role,
    };
    if (linkedAccountIds != null) {
      body['linked_account_ids'] = linkedAccountIds;
    }
    final resp =
        await _postWithRetry(uri, _headers, body: jsonEncode(body));
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    if (map['success'] != true) {
      throw StateError(map['message']?.toString() ?? 'create user failed');
    }
    final u = map['user'] as Map<String, dynamic>?;
    if (u == null) return null;
    return ManagedUserRow.fromJson(u);
  }

  /// DELETE /api/users/:id（仅管理员）。失败时抛出 [StateError]。
  Future<void> deleteUser(int userId) async {
    final uri = Uri.parse('${_normalizedBase}api/users/$userId');
    final resp = await http.delete(uri, headers: _headers).timeout(_timeout);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    if (map['success'] != true) {
      throw StateError(map['message']?.toString() ?? '删除失败');
    }
  }

  /// POST /api/strategy-analyst/auto-net-test（仅 strategy_analyst）
  Future<String> postStrategyAnalystAutoNetTest({String? botId}) async {
    final uri = Uri.parse('${_normalizedBase}api/strategy-analyst/auto-net-test');
    final body = <String, dynamic>{};
    if (botId != null && botId.trim().isNotEmpty) {
      body['bot_id'] = botId.trim();
    }
    final resp =
        await _postWithRetry(uri, _headers, body: jsonEncode(body));
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    if (map['success'] != true) {
      throw StateError(map['message']?.toString() ?? 'auto net test failed');
    }
    return map['message']?.toString() ?? 'ok';
  }

  ManagedUserRow _parsePatchUserRequired(http.Response resp) {
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    if (map['success'] != true) {
      throw StateError(map['message']?.toString() ?? '保存失败');
    }
    final u = map['user'] as Map<String, dynamic>?;
    if (u == null) throw StateError('保存失败');
    return ManagedUserRow.fromJson(u);
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

  Future<BotOperationResponse> seasonStartBot(String botId) async {
    final uri = Uri.parse(
      '${_normalizedBase}api/tradingbots/$botId/season-start',
    );
    final resp = await _postWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return BotOperationResponse.fromJson(map);
  }

  Future<BotOperationResponse> seasonStopBot(String botId) async {
    final uri = Uri.parse(
      '${_normalizedBase}api/tradingbots/$botId/season-stop',
    );
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

  Future<TradingbotEventsResponse> getTradingbotEvents(
    String botId, {
    int limit = 100,
  }) async {
    final uri = Uri.parse(
      '${_normalizedBase}api/tradingbots/$botId/tradingbot-events?limit=$limit',
    );
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return TradingbotEventsResponse.fromJson(map);
  }

  /// OKX 日线波动 |高−低| + 账户现金日增量（UTC）。失败时 success=false，message 为原因。
  Future<StrategyDailyEfficiencyResponse> getStrategyDailyEfficiency(
    String botId, {
    String instId = 'PEPE-USDT-SWAP',
    int days = 90,
  }) async {
    final uri = Uri.parse(
      '${_normalizedBase}api/tradingbots/$botId/strategy-daily-efficiency'
      '?inst_id=${Uri.encodeQueryComponent(instId)}&days=$days',
    );
    final resp = await _getWithRetry(uri, _headers);
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return StrategyDailyEfficiencyResponse.fromJson(map);
  }
}
