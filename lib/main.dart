import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

void main() {
  runApp(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ja', 'JP')],
      home: const SleepGuardApp(),
      debugShowCheckedModeBanner: false,
    ),
  );
}

class SleepGuardApp extends StatefulWidget {
  const SleepGuardApp({super.key});

  @override
  State<SleepGuardApp> createState() => _SleepGuardAppState();
}

class _SleepGuardAppState extends State<SleepGuardApp> {
  // 設定値（デフォルト値）
  double _motionThreshold = 2.0;
  int _timeToAlert = 10;

  // 状態管理用
  bool _isMonitoring = false;
  String _statusMessage = "停止中";
  DateTime _lastMoveTime = DateTime.now();
  StreamSubscription? _accelerometerSubscription;
  Timer? _checkTimer;

  // 直前のセンサー値
  List<double>? _userAccelerometerValues;

  @override
  void initState() {
    super.initState();
    // 画面が消えないようにする（センサー停止防止）
    WakelockPlus.enable();
    _loadSettings();
  }

  // 設定の読み込み
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _motionThreshold = prefs.getDouble('motionThreshold') ?? 2.0;
      _timeToAlert = prefs.getInt('timeToAlert') ?? 10;
    });
  }

  // 設定の保存
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('motionThreshold', _motionThreshold);
    await prefs.setInt('timeToAlert', _timeToAlert);
  }

  @override
  void dispose() {
    _stopMonitoring();
    WakelockPlus.disable();
    super.dispose();
  }

  // 監視スタート
  void _startMonitoring() {
    setState(() {
      _isMonitoring = true;
      _statusMessage = "監視開始\n体につけてください";
      _lastMoveTime = DateTime.now();
    });

    _accelerometerSubscription = userAccelerometerEventStream().listen((
      UserAccelerometerEvent event,
    ) {
      _checkMotion(event);
    });

    _checkTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final now = DateTime.now();
      final difference = now.difference(_lastMoveTime).inSeconds;

      if (difference >= _timeToAlert) {
        _triggerAlarm();
      }

      if (_isMonitoring) {
        setState(() {
          _statusMessage = "静止: ${difference}s / ${_timeToAlert}s";
        });
      }
    });
  }

  // 監視ストップ
  void _stopMonitoring() {
    _accelerometerSubscription?.cancel();
    _checkTimer?.cancel();
    setState(() {
      _isMonitoring = false;
      _statusMessage = "停止中";
    });
  }

  void _checkMotion(UserAccelerometerEvent event) {
    if (_userAccelerometerValues == null) {
      _userAccelerometerValues = [event.x, event.y, event.z];
      return;
    }

    double deltaX = (event.x - _userAccelerometerValues![0]).abs();
    double deltaY = (event.y - _userAccelerometerValues![1]).abs();
    double deltaZ = (event.z - _userAccelerometerValues![2]).abs();

    double totalMovement = deltaX + deltaY + deltaZ;

    if (totalMovement > _motionThreshold) {
      _lastMoveTime = DateTime.now();
    }

    _userAccelerometerValues = [event.x, event.y, event.z];
  }

  Future<void> _triggerAlarm() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 500, 200, 500]);
    }

    setState(() {
      _statusMessage = "動いて！";
    });
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.all(16),
              height: MediaQuery.of(context).size.height * 0.8,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "設定",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Divider(color: Colors.white24),
                    _buildSettingItem(
                      label: "感度 (低いほど敏感)",
                      value: _motionThreshold.toStringAsFixed(1),
                      onDecrement: () {
                        if (_motionThreshold > 0.5) {
                          setState(() => _motionThreshold -= 0.5);
                          setModalState(() {});
                          _saveSettings();
                        }
                      },
                      onIncrement: () {
                        if (_motionThreshold < 10.0) {
                          setState(() => _motionThreshold += 0.5);
                          setModalState(() {});
                          _saveSettings();
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildSettingItem(
                      label: "アラート時間 (秒)",
                      value: _timeToAlert.toString(),
                      onDecrement: () {
                        if (_timeToAlert > 5) {
                          setState(() => _timeToAlert -= 5);
                          setModalState(() {});
                          _saveSettings();
                        }
                      },
                      onIncrement: () {
                        if (_timeToAlert < 60) {
                          setState(() => _timeToAlert += 5);
                          setModalState(() {});
                          _saveSettings();
                        }
                      },
                    ),
                    const SizedBox(height: 20),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        "閉じる",
                        style: TextStyle(color: Colors.blueAccent),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSettingItem({
    required String label,
    required String value,
    required VoidCallback onDecrement,
    required VoidCallback onIncrement,
  }) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(
                Icons.remove_circle_outline,
                color: Colors.redAccent,
                size: 30,
              ),
              onPressed: onDecrement,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.add_circle_outline,
                color: Colors.greenAccent,
                size: 30,
              ),
              onPressed: onIncrement,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isMonitoring ? Colors.black : Colors.white,
      appBar: AppBar(
        title: const Text('居眠りブロッカー', style: TextStyle(fontSize: 16)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              Text(
                _statusMessage,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _isMonitoring ? Colors.white : Colors.black,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _isMonitoring ? _stopMonitoring : _startMonitoring,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 30,
                    vertical: 15,
                  ),
                  backgroundColor: _isMonitoring
                      ? Colors.redAccent
                      : Colors.blueAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: Text(
                  _isMonitoring ? '停止' : '監視開始',
                  style: const TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),
              const SizedBox(height: 40), // 下部に余白を持たせてスクロール可能に
            ],
          ),
        ),
      ),
    );
  }
}
