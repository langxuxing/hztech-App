import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../secure/prefs.dart';

class BotListScreen extends StatefulWidget {
  const BotListScreen({super.key});

  @override
  State<BotListScreen> createState() => _BotListScreenState();
}

class _BotListScreenState extends State<BotListScreen> {
  final _prefs = SecurePrefs();
  List<UnifiedTradingBot> _list = [];
  bool _loading = true;
  String? _error;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.getTradingBots();
      if (!mounted) return;
      setState(() {
        _list = resp.botList;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _onAction(UnifiedTradingBot bot, String action) {
    if (action == 'stop') {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认停止'),
          content: const Text('确定要停止该策略吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _doStop(bot);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }
    if (action == 'restart') {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认重启'),
          content: const Text('确定要重启该策略吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _doRestart(bot);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }
    _doStart(bot);
  }

  Future<void> _doStart(UnifiedTradingBot bot) async {
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.startBot(bot.tradingbotId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(resp.success ? '启动成功' : (resp.message ?? '启动失败'))),
      );
      if (resp.success) _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请求失败: $e')));
    }
  }

  Future<void> _doStop(UnifiedTradingBot bot) async {
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.stopBot(bot.tradingbotId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(resp.success ? '停止成功' : (resp.message ?? '停止失败'))),
      );
      if (resp.success) _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请求失败: $e')));
    }
  }

  Future<void> _doRestart(UnifiedTradingBot bot) async {
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(baseUrl, token: token);
      final resp = await api.restartBot(bot.tradingbotId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(resp.success ? '重启成功' : (resp.message ?? '重启失败'))),
      );
      if (resp.success) _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请求失败: $e')));
    }
  }

  String _statusText(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    if (running) return '运行中';
    if (bot.status == 'error') return '异常';
    return '已停止';
  }

  Color _statusColor(UnifiedTradingBot bot) {
    final running = bot.status == 'running' || bot.isRunning == true;
    if (running) return Colors.green;
    if (bot.status == 'error') return Colors.red;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('策略管理')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading && _list.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _list.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _list.length,
                    itemBuilder: (context, i) {
                      final bot = _list[i];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      bot.tradingbotName ?? bot.tradingbotId,
                                      style: Theme.of(context).textTheme.titleMedium,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _statusColor(bot).withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      _statusText(bot),
                                      style: TextStyle(
                                        color: _statusColor(bot),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (bot.exchangeAccount != null &&
                                  bot.exchangeAccount!.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text('账户: ${bot.exchangeAccount}'),
                                ),
                              if (bot.symbol != null && bot.symbol!.isNotEmpty)
                                Text('交易对: ${bot.symbol}'),
                              if (bot.strategyName != null &&
                                  bot.strategyName!.isNotEmpty)
                                Text('策略: ${bot.strategyName}'),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: () => _onAction(bot, 'start'),
                                    child: const Text('启动'),
                                  ),
                                  TextButton(
                                    onPressed: () => _onAction(bot, 'stop'),
                                    child: const Text('停止'),
                                  ),
                                  TextButton(
                                    onPressed: () => _onAction(bot, 'restart'),
                                    child: const Text('重启'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
