import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'secure/prefs.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'screens/web/web_main_shell.dart';
import 'theme/finance_style.dart';
import 'widgets/backend_health_guard.dart';
import 'widgets/water_background.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HzQuantApp());
}

class HzQuantApp extends StatelessWidget {
  const HzQuantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Web3+AI量化平台',
      debugShowCheckedModeBanner: false,
      theme: () {
        final base = ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
        );
        return base.copyWith(
          colorScheme: base.colorScheme.copyWith(
            primary: AppFinanceStyle.textProfit,
            onPrimary: AppFinanceStyle.textDefault,
            secondary: AppFinanceStyle.textProfit,
            onSecondary: AppFinanceStyle.textDefault,
            error: AppFinanceStyle.textLoss,
            onError: AppFinanceStyle.textDefault,
            onSurface: AppFinanceStyle.textDefault,
            onSurfaceVariant: AppFinanceStyle.textDefault,
          ),
          scaffoldBackgroundColor: AppFinanceStyle.backgroundDark,
          textTheme: base.textTheme.apply(
            bodyColor: AppFinanceStyle.textDefault,
            displayColor: AppFinanceStyle.textDefault,
          ),
          primaryTextTheme: base.primaryTextTheme.apply(
            bodyColor: AppFinanceStyle.textDefault,
            displayColor: AppFinanceStyle.textDefault,
          ),
          iconTheme:
              base.iconTheme.copyWith(color: AppFinanceStyle.textDefault),
        );
      }(),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  final _prefs = SecurePrefs();
  bool _loading = true;
  bool _loggedIn = false;
  bool _needUnlock = false;

  Future<void> _checkAuth() async {
    final loggedIn = await _prefs.isLoggedIn;
    final fingerprintOn = await _prefs.fingerprintEnabled;
    final unlocked = await _prefs.isUnlocked;
    if (!mounted) return;
    setState(() {
      _loggedIn = loggedIn;
      // Web 无法使用生物识别解锁，避免卡在仅指纹页
      _needUnlock = loggedIn && fingerprintOn && !unlocked && !kIsWeb;
      _loading = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  void _onLoginSuccess() {
    setState(() {
      _loggedIn = true;
      _needUnlock = false;
    });
  }

  void _onLogout() {
    setState(() {
      _loggedIn = false;
      _needUnlock = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: WaterBackground(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (!_loggedIn || _needUnlock) {
      return LoginScreen(
        onLoginSuccess: _onLoginSuccess,
        unlockMode: _loggedIn && _needUnlock,
      );
    }
    if (kIsWeb) {
      return BackendHealthGuard(
        child: WebMainShell(onLogout: _onLogout),
      );
    }
    return BackendHealthGuard(
      child: MainScreen(onLogout: _onLogout),
    );
  }
}
