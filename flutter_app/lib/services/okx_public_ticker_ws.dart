import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

/// OKX 公共频道 tickers（无需 API Key），用于 Web 端持仓卡片实时现价。
/// 见 https://www.okx.com/docs-v5/zh/#websocket-api-public-channel-tickers-channel
class OkxPublicTickerWs {
  OkxPublicTickerWs();

  static const _url = 'wss://ws.okx.com:8443/ws/v5/public';

  WebSocketChannel? _channel;
  StreamController<double>? _out;
  Timer? _pingTimer;
  StreamSubscription<dynamic>? _sub;
  String? _instId;
  int _reconnectGen = 0;

  Stream<double>? get priceStream => _out?.stream;

  void subscribe(String instId) {
    final id = instId.trim();
    if (id.isEmpty) {
      dispose();
      return;
    }

    if (_instId == id && _channel != null) return;

    if (_instId != null && _instId != id) {
      dispose();
    } else {
      _tearDownConnection();
    }

    _instId = id;
    _out ??= StreamController<double>.broadcast();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_url));
      _channel!.sink.add(
        jsonEncode({
          'op': 'subscribe',
          'args': [
            {'channel': 'tickers', 'instId': id},
          ],
        }),
      );

      _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        try {
          _channel?.sink.add('ping');
        } catch (_) {}
      });

      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _tearDownConnection();
    final id = _instId;
    if (id == null || id.isEmpty) return;
    final gen = ++_reconnectGen;
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (gen != _reconnectGen) return;
      if (_instId != id) return;
      if (_channel != null) return;
      subscribe(id);
    });
  }

  void _onMessage(dynamic message) {
    final String? text = switch (message) {
      final String s => s,
      final Uint8List u => utf8.decode(u),
      final List<int> bytes => utf8.decode(bytes),
      _ => null,
    };
    if (text == null) return;
    if (text == 'pong') return;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final data = decoded['data'];
      if (data is! List) return;
      for (final row in data) {
        if (row is! Map) continue;
        final last = row['last'];
        if (last == null) continue;
        final v = double.tryParse(last.toString());
        if (v != null && v > 0) {
          _out?.add(v);
        }
      }
    } catch (_) {}
  }

  void _tearDownConnection() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void dispose() {
    _reconnectGen++;
    _instId = null;
    _tearDownConnection();
    final o = _out;
    _out = null;
    if (o != null && !o.isClosed) {
      o.close();
    }
  }
}
