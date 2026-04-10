import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:async';

import '../api/client.dart';
import '../app_update_prompt.dart';
import '../constants/app_download.dart';
import '../debug_ingest_log.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../widgets/water_background.dart';

/// 科技金融色系：深空蓝、电光青；正文与全局 textDefault 一致
const Color _deepBlue = Color(0xFF0A1628);
const Color _electricCyan = Color(0xFF00D4FF);

/// 登录页暗色输入与按钮渐变（参考设计稿：青→天蓝→宝蓝）
const Color _loginInputFill = Color(0xFF0B1220);
const Color _loginInputBorder = Color(0xFF334155);
const Color _loginBtnCyan = Color(0xFF22D3EE);
const Color _loginBtnBlue = Color(0xFF2563EB);

/// 登录页固定表单宽度
const double _formWidth = 320;

/// 登录页隐藏入口：后端 **根**基址（[ApiClient] 会再拼 `api/...`）。
/// 线上 nginx 将 `https://www.sfund.now/api/` 反代到 BaasAPI 时，此处填 `https://www.sfund.now/`，勿填 `.../api/`。
const List<({String label, String apiBaseUrl})> _kBackendPresets = [
  (label: '开发环境[本地]', apiBaseUrl: 'http://127.0.0.1:9001/'),
  (label: '开发环境', apiBaseUrl: 'http://192.168.3.41:9001/'),
  (label: '线上(nginx)', apiBaseUrl: 'https://www.sfund.now/'),
  (label: 'AWS-Alpha 直连', apiBaseUrl: 'http://54.66.108.150:9001/'),
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
    if (_logoSecretTapCount >= 3) {
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
    var selectedIndex = 0;
    for (var i = 0; i < _kBackendPresets.length; i++) {
      if (_normalizeBaseUrl(_kBackendPresets[i].apiBaseUrl) == currentNorm) {
        selectedIndex = i;
        break;
      }
    }

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogBodyContext, setDialogState) {
            return AlertDialog(
              title: const Text('服务器地址'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '线上请选「nginx」：根地址为 https://www.sfund.now/（nginx 把 /api 转到后端）；'
                      '勿填以 /api/ 结尾。直连 EC2 调试用「AWS-Alpha 直连」。',
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
                          value: selectedIndex,
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
                              selectedIndex = i ?? 0;
                            });
                          },
                        ),
                      ),
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
                    final migrated = migrateLegacyBackendApiPort(
                      _kBackendPresets[selectedIndex].apiBaseUrl,
                    );
                    final norm = _normalizeBaseUrl(migrated);
                    if (norm.isEmpty) {
                      _showSnack('请选择有效的服务器地址');
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
                    _showSnack('已保存服务器地址');
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
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
          if (Uri.base.scheme.toLowerCase() == 'https' &&
              rawUrl.trim().toLowerCase().startsWith('http://')) {
            msg =
                '当前为 HTTPS 页面，浏览器会拦截对 HTTP 接口的请求（混合内容）。请改用 HTTPS 的 API 根地址（需反代/证书），'
                '或清空本地保存的后端地址后重载；勿在 https 站点填写 http://54.x 直连。';
          } else {
            msg =
              '无法连接后端 $rawUrl。请确认 API 已启动（例如 ./baasapi/run_local.sh，默认 API 端口 9001），'
              '并填写 API 根地址（线上 nginx 入口为 https://www.sfund.now/，勿填 …/api/）；'
              '勿将浏览器打开的 Web 静态端口当成 API。';
          }
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

  Future<void> _openApkDownload() async {
    final uri = Uri.tryParse(awsReleaseApkDownloadUrl());
    if (uri == null) {
      _showSnack('下载地址无效');
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    if (!ok) {
      _showSnack('无法打开下载链接');
    }
  }

  Widget _buildAppTitle() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            colors: [_electricCyan, _loginBtnBlue],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ).createShader(bounds),
          child: const Text(
            'Web3+AI 量化交易平台',
            style: TextStyle(
              color: AppFinanceStyle.textDefault,
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
        color: AppFinanceStyle.textDefault.withValues(alpha: 0.65),
        fontStyle: FontStyle.italic,
      ),
      labelStyle: TextStyle(
        color: AppFinanceStyle.textDefault.withValues(alpha: 0.85),
      ),
      filled: true,
      fillColor: _loginInputFill.withValues(alpha: 0.72),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: _loginInputBorder.withValues(alpha: 0.85),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: _loginInputBorder.withValues(alpha: 0.75),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _loginBtnCyan, width: 1.5),
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
          // foregroundColor 与全局 textDefault 一致。
          title: const Text('欢迎使用Web3+AI量化交易平台'),
          backgroundColor: Colors.black,
          foregroundColor: AppFinanceStyle.textDefault,
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

    final screenW = MediaQuery.sizeOf(context).width;

    return Scaffold(
      backgroundColor: _deepBlue,
      appBar: AppBar(
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: SizedBox(
          width: double.infinity,
          child: Center(child: _buildAppTitle()),
        ),
        actions: [
          TextButton.icon(
            onPressed: _loading ? null : _openApkDownload,
            icon: Icon(Icons.download_rounded, color: _electricCyan.withValues(alpha: 0.95), size: 20),
            label: Text(
              'APK',
              style: TextStyle(
                color: _electricCyan.withValues(alpha: 0.95),
                fontWeight: FontWeight.w600,
              ),
            ),
            style: TextButton.styleFrom(
              foregroundColor: _electricCyan,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
        ],
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: AppFinanceStyle.textDefault,
      ),
      body: WaterBackground(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bodyH = constraints.maxHeight;
            final halfH = bodyH * 0.5;
            // 书法图宽高比约 1408:452，限制在「上半屏」内不溢出
            final kongMaxByHeight = halfH * (1408 / 452);
            final formW = _formWidth.clamp(0.0, screenW - 48);
            final kongW = kIsWeb
                ? (screenW * 0.72)
                      .clamp(760.0, 1120.0)
                      .toDouble()
                      .clamp(0.0, kongMaxByHeight)
                : kongMaxByHeight.clamp(240.0, screenW);

            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                // 上半屏：kong-zhuo 居中（不与下半屏表单重叠）
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: halfH,
                  child: IgnorePointer(
                    child: Center(
                      // 双层柔化：横向淡化左右「硬边」，纵向保留与下半屏衔接并略淡化顶边
                      child: ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (Rect bounds) => const LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Colors.transparent,
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                          ],
                          stops: [0.0, 0.07, 0.93, 1.0],
                        ).createShader(bounds),
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (Rect bounds) => const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.white,
                              Colors.white,
                              Colors.transparent,
                            ],
                            stops: [0.0, 0.06, 0.66, 1.0],
                          ).createShader(bounds),
                          child: Image.asset(
                            'images/kong-zhuo.png',
                            width: kongW,
                            fit: BoxFit.fitWidth,
                            alignment: Alignment.topCenter,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 下半屏：表单靠底部居中，尽量贴近底部（留出 Logo）
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: halfH,
                  child: SafeArea(
                    top: false,
                    child: LayoutBuilder(
                      builder: (context, lower) {
                        final padBottom = MediaQuery.paddingOf(context).bottom;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    8,
                                    24,
                                    12,
                                  ),
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      minHeight:
                                          (lower.maxHeight - 80 - padBottom)
                                              .clamp(0.0, double.infinity),
                                    ),
                                    child: Align(
                                      alignment: Alignment.bottomCenter,
                                      child: SizedBox(
                                        width: formW,
                                        child: Material(
                                          color: Colors.transparent,
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              TextField(
                                                controller: _usernameCtrl,
                                                style: const TextStyle(
                                                  color: AppFinanceStyle
                                                      .textDefault,
                                                ),
                                                decoration: inputDecoration
                                                    .copyWith(
                                                      labelText: '用户名',
                                                      hintText: '用户名',
                                                    ),
                                                textInputAction:
                                                    TextInputAction.next,
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: _passwordCtrl,
                                                style: const TextStyle(
                                                  color: AppFinanceStyle
                                                      .textDefault,
                                                ),
                                                decoration: inputDecoration
                                                    .copyWith(
                                                      labelText: '密码',
                                                      hintText: '密码',
                                                      suffixIcon: IconButton(
                                                        icon: Icon(
                                                          _obscurePassword
                                                              ? Icons
                                                                    .visibility_off
                                                              : Icons
                                                                    .visibility,
                                                          color: AppFinanceStyle
                                                              .textDefault,
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
                                                onSubmitted: (_) =>
                                                    _performLogin(),
                                              ),
                                              const SizedBox(height: 24),
                                              SizedBox(
                                                width: double.infinity,
                                                height: 48,
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          14,
                                                        ),
                                                    boxShadow: [
                                                      BoxShadow(
                                                        color: _loginBtnBlue
                                                            .withValues(
                                                              alpha: 0.35,
                                                            ),
                                                        blurRadius: 14,
                                                        spreadRadius: 0,
                                                      ),
                                                    ],
                                                    gradient:
                                                        const LinearGradient(
                                                          colors: [
                                                            _loginBtnCyan,
                                                            _loginBtnBlue,
                                                          ],
                                                          begin: Alignment
                                                              .centerLeft,
                                                          end: Alignment
                                                              .centerRight,
                                                        ),
                                                  ),
                                                  child: Material(
                                                    color: Colors.transparent,
                                                    child: InkWell(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            14,
                                                          ),
                                                      onTap: _loading
                                                          ? null
                                                          : _performLogin,
                                                      child: Center(
                                                        child: _loading
                                                            ? SizedBox(
                                                                width: 24,
                                                                height: 24,
                                                                child: CircularProgressIndicator(
                                                                  strokeWidth:
                                                                      2,
                                                                  color: AppFinanceStyle
                                                                      .textDefault,
                                                                ),
                                                              )
                                                            : const Text(
                                                                '登 录',
                                                                style: TextStyle(
                                                                  color: AppFinanceStyle
                                                                      .textDefault,
                                                                  fontSize: 16,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  letterSpacing:
                                                                      4,
                                                                ),
                                                              ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                              FutureBuilder<bool>(
                                                future:
                                                    _prefs.fingerprintEnabled,
                                                builder: (context, snap) {
                                                  final enabled =
                                                      snap.data == true;
                                                  return Center(
                                                    child: IconButton(
                                                      iconSize: 40,
                                                      splashRadius: 28,
                                                      onPressed:
                                                          enabled && !_loading
                                                          ? _authenticateBiometric
                                                          : null,
                                                      icon: Icon(
                                                        Icons.fingerprint,
                                                        color: enabled
                                                            ? _electricCyan
                                                            : AppFinanceStyle
                                                                  .textDefault
                                                                  .withValues(
                                                                    alpha: 0.4,
                                                                  ),
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
                                ),
                              ),
                            ),
                            Padding(
                              padding: EdgeInsets.only(bottom: 8 + padBottom),
                              child: Center(
                                child: GestureDetector(
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
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
