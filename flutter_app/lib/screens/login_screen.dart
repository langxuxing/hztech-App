import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../api/client.dart';
import '../auth/allowed_users.dart';
import '../secure/prefs.dart';

/// 海蓝色（用于标题等）
const Color _seaBlue = Color(0xFF006994);

/// 登录页固定表单宽度，不随窗口变化
const double _formWidth = 320;

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
  bool _loading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _performLogin() async {
    final user = _usernameCtrl.text.trim();
    final pass = _passwordCtrl.text.trim();
    if (user.isEmpty || pass.isEmpty) {
      _showSnack('请输入用户名和密码');
      return;
    }
    if (!validateUser(user, pass)) {
      _showSnack('用户名或密码错误');
      return;
    }
    setState(() => _loading = true);
    try {
      final baseUrl = await _prefs.backendBaseUrl;
      final api = ApiClient(baseUrl);
      await api.getAccountProfit();
      await _prefs.setAuthToken(
        'token_${user}_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (!mounted) return;
      widget.onLoginSuccess();
    } catch (e) {
      if (!mounted) return;
      _showSnack('网络异常，使用本地登录: $e');
      await _prefs.setAuthToken(
        'token_${user}_${DateTime.now().millisecondsSinceEpoch}',
      );
      widget.onLoginSuccess();
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

  @override
  Widget build(BuildContext context) {
    final inputDecoration = InputDecoration(
      labelText: '',
      hintStyle: TextStyle(color: Colors.grey.shade400),
      labelStyle: TextStyle(color: Colors.grey.shade400),
      filled: true,
      fillColor: Colors.grey.shade900,
      border: const OutlineInputBorder(),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Colors.grey.shade700),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: _seaBlue, width: 2),
      ),
    );

    if (widget.unlockMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('欢迎使用禾正量化'),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '使用指纹解锁',
                style: TextStyle(fontSize: 18, color: Colors.grey.shade300),
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
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('AI量化交易平台'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final screenHeight = constraints.maxHeight;
            // 上方区域（约 70%）：logo；下方区域（约 30%）：表单
            final topHeight = screenHeight * 0.70;
            final bottomHeight = screenHeight * 0.30;
            return Column(
              children: [
                // 上方：禾正 logo（hezheng_logo，即 hztech_logo），尺寸放大 2 倍（原 120x48 -> 240x96）
                SizedBox(
                  height: topHeight,
                  child: Center(
                    child: Image.asset(
                      'images/hztech_logo.png',
                      width: 240,
                      height: 96,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                // 下方 30%：用户名、密码、登录
                SizedBox(
                  height: bottomHeight,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Center(
                      child: SizedBox(
                        width: _formWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextField(
                              controller: _usernameCtrl,
                              style: const TextStyle(color: Colors.white),
                              decoration: inputDecoration.copyWith(
                                labelText: '用户名',
                                hintText: '用户名',
                              ),
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _passwordCtrl,
                              style: const TextStyle(color: Colors.white),
                              decoration: inputDecoration.copyWith(
                                labelText: '密码',
                                hintText: '密码',
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    color: Colors.grey.shade400,
                                  ),
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                ),
                              ),
                              obscureText: _obscurePassword,
                              onSubmitted: (_) => _performLogin(),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(0, 48),
                                  backgroundColor: _seaBlue,
                                ),
                                onPressed: _loading ? null : _performLogin,
                                child: _loading
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text('登录'),
                              ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: FutureBuilder<bool>(
                                future: _prefs.fingerprintEnabled,
                                builder: (context, snap) {
                                  final enabled = snap.data == true;
                                  return FilledButton.tonalIcon(
                                    onPressed: enabled && !_loading
                                        ? _authenticateBiometric
                                        : null,
                                    icon: const Icon(Icons.fingerprint),
                                    label: Text(enabled ? '指纹登录' : '请先登录并在设置中开启指纹'),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
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
