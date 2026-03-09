import 'package:flutter/material.dart';

import 'secure/prefs.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
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
      title: '禾正量化',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
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
      _needUnlock = loggedIn && fingerprintOn && !unlocked;
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
    return MainScreen(onLogout: _onLogout);
  }
}
