import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import 'dart:async';

import '../api/client.dart';
import '../app_update_prompt.dart';
import '../debug_ingest_log.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../widgets/water_background.dart';

/// 科技金融色系：深空蓝、电光青；正文与全局 textDefault 一致
const Color _deepBlue = Color(0xFF0A1628);
const Color _electricCyan = Color(0xFF00D4FF);
const Color _electricPurple = Color(0xFF6366F1);

/// 登录页固定表单宽度
const double _formWidth = 320;

/// 副标题诗句（保留原文案）
const String _tagline = '知空守拙，细水长流；顺势扬帆，乘风破浪';

/// 登录页隐藏入口：后端 API 基址预设（与 API 服务端口一致，默认 9001）。
const List<({String label, String apiBaseUrl})> _kBackendPresets = [
  (label: '开发环境[本地]', apiBaseUrl: 'http://127.0.0.1:9001/'),
  (label: '开发环境', apiBaseUrl: 'http://192.168.3.41:9001/'),
  (label: 'AWS-Alpha', apiBaseUrl: 'http://54.66.108.150:9001/'),
  (label: 'AWS-Defi', apiBaseUrl: 'http://54.252.181.151:9001/'),
];

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.onLoginSuccess,
    this.unlockMode = false,
  });

  final VoidCallback onLoginSuccess;
  final bool unlockMode;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _prefs = SecurePrefs();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _backendUrlCtrl = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  Timer? _logoTapResetTimer;
  int _logoSecretTapCount = 0;

  @override
  void initState() {
    super.initState();
    _prefs.backendBaseUrl.then((url) {
      // #region agent log
      unawaited(
        debugIngestLog(
          location: 'login_screen.dart:initState',
          message: 'backend_url_for_field',
          hypothesisId: 'H4',
          data: <String, Object?>{
            'urlFromPrefs': url,
            'controllerWasEmpty': _backendUrlCtrl.text.isEmpty,
          },
        ),
      );
      // #endregion
      if (mounted && _backendUrlCtrl.text.isEmpty) {
        _backendUrlCtrl.text = url;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        AppUpdatePrompt.checkIfNeeded(context, url);
      });
    });
  }

  @override
  void dispose() {
    _logoTapResetTimer?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _backendUrlCtrl.dispose();
    super.dispose();
  }

  /// 预设项副标题：host:port（与下拉展示一致）
  String _presetHostPort(String apiBaseUrl) {
    try {
      final u = Uri.parse(apiBaseUrl);
      if (u.hasPort) return '${u.host}:${u.port}';
      return u.host;
    } catch (_) {
      return apiBaseUrl;
    }
  }

  void _onLogoSecretTap() {
    _logoTapResetTimer?.cancel();
    _logoSecretTapCount += 1;
    if (_logoSecretTapCount >= 5) {
      _logoSecretTapCount = 0;
      _showBackendUrlSettingsDialog();
      return;
    }
    _logoTapResetTimer = Timer(const Duration(seconds: 2), () {
      _logoSecretTapCount = 0;
    });
  }

  void _showBackendUrlSettingsDialog() {
    final currentNorm = _normalizeBaseUrl(_backendUrlCtrl.text);
    var selectedIndex = -1;
    for (var i = 0; i < _kBackendPresets.length; i++) {
      if (_normalizeBaseUrl(_kBackendPresets[i].apiBaseUrl) == currentNorm) {
        selectedIndex = i;
        break;
      }
    }
    final customCtrl = TextEditingController(
      text: _backendUrlCtrl.text.trim().isEmpty
          ? _kBackendPresets.first.apiBaseUrl
          : _backendUrlCtrl.text.trim(),
    );

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogBodyContext, setDialogState) {
            return AlertDialog(
              title: const Text('后端 API 地址'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '此处填写 API 根地址（默认本机 9001）。浏览器打开 Flutter Web 使用静态站端口（本地多为 9000）。',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppFinanceStyle.textDefault,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: '环境',
                        border: OutlineInputBorder(),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          isExpanded: true,
                          value: selectedIndex >= 0 ? selectedIndex : null,
                          hint: const Text('选择预设或下方手动填写'),
                          items: [
                            for (var i = 0; i < _kBackendPresets.length; i++)
                              DropdownMenuItem<int>(
                                value: i,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(_kBackendPresets[i].label),
                                    Text(
                                      _presetHostPort(
                                        _kBackendPresets[i].apiBaseUrl,
                                      ),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppFinanceStyle.textDefault,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          onChanged: (i) {
                            setDialogState(() {
                              selectedIndex = i ?? -1;
                              if (i != null) {
                                customCtrl.text = _kBackendPresets[i].apiBaseUrl;
                              }
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: customCtrl,
                      decoration: const InputDecoration(
                        labelText: 'API 根地址',
                        hintText: 'http://主机:9001/',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    final migrated =
                        migrateLegacyBackendApiPort(customCtrl.text);
                    final norm = _normalizeBaseUrl(migrated);
                    if (norm.isEmpty) {
                      _showSnack('请输入有效的 API 地址');
                      return;
                    }
                    try {
                      await _prefs.setBackendBaseUrl(norm);
                    } catch (e) {
                      if (!mounted) return;
                      _showSnack('保存失败: $e');
                      return;
                    }
                    if (!mounted) return;
                    setState(() => _backendUrlCtrl.text = norm);
                    if (dialogBodyContext.mounted) {
                      Navigator.of(dialogBodyContext).pop();
                    } else if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                    _showSnack('已保存后端地址');
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    ).then((_) => customCtrl.dispose());
  }

  String _normalizeBaseUrl(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return t;
    final u = t.startsWith('http') ? t : 'http://$t';
    return u.endsWith('/') ? u : '$u/';
  }

  Future<void> _performLogin() async {
    final user = _usernameCtrl.text.trim();
    final pass = _passwordCtrl.text.trim();
    if (user.isEmpty || pass.isEmpty) {
      _showSnack('请输入用户名和密码');
      return;
    }
    final rawUrl = _backendUrlCtrl.text.trim();
    if (rawUrl.isEmpty) {
      _showSnack('请输入后端地址');
      return;
    }
    setState(() => _loading = true);
    try {
      final normalizedInput = _normalizeBaseUrl(rawUrl);
      final baseUrl = migrateLegacyBackendApiPort(rawUrl);
      if (mounted && baseUrl != normalizedInput) {
        _backendUrlCtrl.text = baseUrl;
      }
      // #region agent log
      unawaited(
        debugIngestLog(
          location: 'login_screen.dart:_performLogin',
          message: 'before_api_login',
          hypothesisId: 'H4_H5',
          data: <String, Object?>{
            'rawUrl': rawUrl,
            'normalizedInput': normalizedInput,
            'baseUrlAfterMigrate': baseUrl,
            'controllerText': _backendUrlCtrl.text,
          },
        ),
      );
      // #endregion
      final api = ApiClient(baseUrl);
      final resp = await api.login(user, pass);
      if (!mounted) return;
      if (resp.success && resp.token != null && resp.token!.isNotEmpty) {
        await _prefs.setAuthToken(resp.token);
        await _prefs.setUserRole(resp.role);
        await _prefs.setBackendBaseUrl(baseUrl);
        widget.onLoginSuccess();
      } else {
        _showSnack(resp.message ?? '用户名或密码错误');
      }
    } catch (e) {
      if (!mounted) return;
      final String msg;
      if (e is FormatException && e.message.isNotEmpty) {
        msg = e.message;
      } else {
        final s = e.toString();
        final looksUnreachable =
            s.contains('Failed to fetch') || s.contains('ClientException');
        if (kIsWeb && looksUnreachable) {
          msg =
              '无法连接后端 $rawUrl。请确认 API 已启动（例如 ./server/run_local.sh，默认 API 端口 9001），'
              '并填写 API 根地址（如 http://127.0.0.1:9001/）；勿将浏览器打开的 Web 静态端口当成 API。';
        } else {
          msg = '网络异常: $e';
        }
      }
      _showSnack(msg);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _authenticateBiometric() async {
    final auth = LocalAuthentication();
    final canCheck = await auth.canCheckBiometrics;
    if (!canCheck) {
      _showSnack('设备不支持生物识别');
      return;
    }
    try {
      final ok = await auth.authenticate(
        localizedReason: '使用指纹登录禾正量化',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
      if (!mounted) return;
      if (ok) {
        final until = DateTime.now().millisecondsSinceEpoch + unlockDurationMs;
        await _prefs.setUnlockedUntilMs(until);
        widget.onLoginSuccess();
      } else {
        _showSnack('指纹验证失败');
      }
    } catch (e) {
      _showSnack('指纹验证失败: $e');
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _buildAppTitle() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF00D4FF), Color(0xFF6366F1)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ).createShader(bounds),
          child: const Text(
            'Web3+AI 量化交易平台',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final inputDecoration = InputDecoration(
      labelText: '',
      hintStyle: TextStyle(
        color: AppFinanceStyle.textDefault.withValues(alpha: 0.7),
        fontStyle: FontStyle.italic,
      ),
      labelStyle:
          TextStyle(color: AppFinanceStyle.textDefault.withValues(alpha: 0.8)),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: AppFinanceStyle.textDefault.withValues(alpha: 0.3),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _electricCyan, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );

    if (widget.unlockMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          // 这个部分是配置 AppBar，也就是顶部应用栏的显示内容和样式。
          // title 设置了标题文本 '欢迎使用禾正AI量化交易平台'，显示在顶部中间。
          // backgroundColor: Colors.black 表示 AppBar 的背景色为黑色。
          // foregroundColor: Colors.white 表示标题文本和图标等前景内容为白色，增强对比度和可读性。
          title: const Text('欢迎使用Web3+AI量化交易平台'),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: WaterBackground(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '使用指纹解锁',
                  style: const TextStyle(
                    fontSize: 18,
                    color: AppFinanceStyle.textDefault,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _loading ? null : _authenticateBiometric,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('指纹解锁'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _deepBlue,
      appBar: AppBar(
        title: _buildAppTitle(),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      body: WaterBackground(
        // 上半区书法图；下半区半透明叠层，透出底层水纹与底色
        child: Column(
          children: [
            // 上半区：知空守拙背景图，向上对齐、80% 不透明，不被登录遮挡
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.42,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: Opacity(
                      opacity: 0.8,
                      child: Image.asset(
                        'images/zhikong.png',
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        alignment: Alignment.topCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 下半区：登录表单，半透明渐变（底部略加深以兼顾页脚可读）
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x73001a24),
                      Color(0x85000000),
                      Color(0xA60A1628),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Column(
                        children: [
                          const SizedBox(height: 20),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              child: Center(
                                child: SizedBox(
                                  width: _formWidth,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // 后端地址输入隐藏
                                      const SizedBox(height: 16),
                                      TextField(
                                        controller: _usernameCtrl,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                        decoration: inputDecoration.copyWith(
                                          labelText: '用户名',
                                          hintText: '用户名',
                                        ),
                                        textInputAction: TextInputAction.next,
                                      ),
                                      const SizedBox(height: 16),
                                      TextField(
                                        controller: _passwordCtrl,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                        decoration: inputDecoration
                                            .copyWith(
                                              labelText: '密码',
                                              hintText: '密码',
                                              suffixIcon: IconButton(
                                                icon: Icon(
                                                  _obscurePassword
                                                      ? Icons.visibility_off
                                                      : Icons.visibility,
                                                  color: AppFinanceStyle.textDefault,
                                                  size: 22,
                                                ),
                                                onPressed: () => setState(
                                                  () => _obscurePassword =
                                                      !_obscurePassword,
                                                ),
                                              ),
                                            )
                                            .copyWith(
                                              suffixIconConstraints:
                                                  const BoxConstraints(
                                                    minWidth: 44,
                                                    minHeight: 44,
                                                  ),
                                            ),
                                        obscureText: _obscurePassword,
                                        onSubmitted: (_) => _performLogin(),
                                      ),
                                      const SizedBox(height: 24),
                                      SizedBox(
                                        width: double.infinity,
                                        height: 48,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: _electricCyan.withValues(
                                                  alpha: 0.3,
                                                ),
                                                blurRadius: 12,
                                                spreadRadius: 0,
                                              ),
                                            ],
                                            gradient: const LinearGradient(
                                              colors: [
                                                _electricCyan,
                                                _electricPurple,
                                              ],
                                              begin: Alignment.centerLeft,
                                              end: Alignment.centerRight,
                                            ),
                                          ),
                                          child: Material(
                                            color: Colors.transparent,
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              onTap: _loading
                                                  ? null
                                                  : _performLogin,
                                              child: Center(
                                                child: _loading
                                                    ? const SizedBox(
                                                        width: 24,
                                                        height: 24,
                                                        child:
                                                            CircularProgressIndicator(
                                                              strokeWidth: 2,
                                                              color:
                                                                  Colors.white,
                                                            ),
                                                      )
                                                    : const Text(
                                                        '登 录',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          letterSpacing: 4,
                                                        ),
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),

                                      const SizedBox(height: 12),
                                      FutureBuilder<bool>(
                                        future: _prefs.fingerprintEnabled,
                                        builder: (context, snap) {
                                          final enabled = snap.data == true;
                                          return Center(
                                            child: IconButton(
                                              iconSize: 40,
                                              splashRadius: 28,
                                              onPressed: enabled && !_loading
                                                  ? _authenticateBiometric
                                                  : null,
                                              icon: Icon(
                                                Icons.fingerprint,
                                                color: enabled
                                                    ? _electricCyan
                                                    : AppFinanceStyle.textDefault
                                                        .withValues(alpha: 0.4),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 底部：Logo + 品牌副标题 + 信任徽章
                          Padding(
                            padding: const EdgeInsets.only(top: 28, bottom: 24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _onLogoSecretTap,
                                  child: Image.asset(
                                    'images/hztech_logo.png',
                                    width: 140,
                                    height: 56,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) =>
                                        const SizedBox.shrink(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _tagline,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: AppFinanceStyle.textDefault
                                            .withValues(alpha: 0.85),
                                        height: 1.45,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
