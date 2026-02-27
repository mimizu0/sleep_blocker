import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class AppConfig {
  static const double defaultMotionThreshold = 0.1;
  static const int defaultTimeToAlert = 90;
  static const String keyMotionThreshold = 'motionThreshold';
  static const String keyTimeToAlert = 'timeToAlert';
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
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

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'sleep_blocker_service',
    'Sleep Blocker Service',
    description: 'This channel is used for important notifications.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'sleep_blocker_service',
      initialNotificationTitle: '居眠りブロッカー',
      initialNotificationContent: '初期化中...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  double motionThreshold = AppConfig.defaultMotionThreshold;
  int timeToAlert = AppConfig.defaultTimeToAlert;
  DateTime lastMoveTime = DateTime.now();
  List<double>? userAccelerometerValues;
  Timer? checkTimer;
  StreamSubscription? subscription;

  final prefs = await SharedPreferences.getInstance();
  motionThreshold =
      prefs.getDouble(AppConfig.keyMotionThreshold) ??
      AppConfig.defaultMotionThreshold;
  timeToAlert =
      prefs.getInt(AppConfig.keyTimeToAlert) ?? AppConfig.defaultTimeToAlert;

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  service.on('updateSettings').listen((event) {
    if (event != null) {
      motionThreshold = event['motionThreshold'] ?? motionThreshold;
      timeToAlert = event['timeToAlert'] ?? timeToAlert;
    }
  });

  subscription =
      userAccelerometerEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen((UserAccelerometerEvent event) {
        if (userAccelerometerValues == null) {
          userAccelerometerValues = [event.x, event.y, event.z];
          return;
        }

        double deltaX = (event.x - userAccelerometerValues![0]).abs();
        double deltaY = (event.y - userAccelerometerValues![1]).abs();
        double deltaZ = (event.z - userAccelerometerValues![2]).abs();
        double totalMovement = deltaX + deltaY + deltaZ;

        if (totalMovement > motionThreshold) {
          lastMoveTime = DateTime.now();
        }
        userAccelerometerValues = [event.x, event.y, event.z];
      });

  bool lastAlertState = false;

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(title: "居眠りブロッカー", content: "動作中");
  }

  checkTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
    final now = DateTime.now();
    final difference = now.difference(lastMoveTime).inSeconds;
    final bool isAlert = difference >= timeToAlert;

    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        // 状態（通常/アラート）が変化した時のみ通知を更新
        if (isAlert != lastAlertState) {
          service.setForegroundNotificationInfo(
            title: "居眠りブロッカー",
            content: isAlert ? "起きて！！" : "動作中",
          );
          lastAlertState = isAlert;
        }
      }
    }

    if (isAlert) {
      Vibration.vibrate(pattern: [0, 500, 200, 500]);
    }

    service.invoke('updateStatus', {
      "seconds": difference,
      "timeToAlert": timeToAlert,
      "isAlert": isAlert,
    });
  });

  // 警告を抑制するための利用（実際には保持し続ける必要がある）
  print("Service started with subscription: $subscription, timer: $checkTimer");
}

class SleepGuardApp extends StatefulWidget {
  const SleepGuardApp({super.key});

  @override
  State<SleepGuardApp> createState() => _SleepGuardAppState();
}

class _SleepGuardAppState extends State<SleepGuardApp> {
  double _motionThreshold = AppConfig.defaultMotionThreshold;
  int _timeToAlert = AppConfig.defaultTimeToAlert;
  bool _isMonitoring = false;
  String _statusMessage = "停止中";
  StreamSubscription? _statusSubscription;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkServiceStatus();
    _requestNotificationPermission();
  }

  Future<void> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    }
  }

  Future<void> _checkServiceStatus() async {
    final service = FlutterBackgroundService();
    bool running = await service.isRunning();
    setState(() {
      _isMonitoring = running;
      if (running) {
        _statusMessage = "監視中";
        _listenToStatus();
      }
    });
  }

  void _listenToStatus() {
    _statusSubscription?.cancel();
    _statusSubscription = FlutterBackgroundService().on('updateStatus').listen((
      event,
    ) {
      if (event != null && _isMonitoring) {
        setState(() {
          int seconds = event['seconds'];
          int limit = event['timeToAlert'];
          bool isAlert = event['isAlert'];
          if (isAlert) {
            _statusMessage = "起きて！！";
          } else {
            _statusMessage = "静止: ${seconds}s / ${limit}s";
          }
        });
      }
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _motionThreshold =
          prefs.getDouble(AppConfig.keyMotionThreshold) ??
          AppConfig.defaultMotionThreshold;
      _timeToAlert =
          prefs.getInt(AppConfig.keyTimeToAlert) ??
          AppConfig.defaultTimeToAlert;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(AppConfig.keyMotionThreshold, _motionThreshold);
    await prefs.setInt(AppConfig.keyTimeToAlert, _timeToAlert);

    // 実行中ならバックグラウンドに通知
    if (_isMonitoring) {
      FlutterBackgroundService().invoke('updateSettings', {
        AppConfig.keyMotionThreshold: _motionThreshold,
        AppConfig.keyTimeToAlert: _timeToAlert,
      });
    }
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    super.dispose();
  }

  void _startMonitoring() async {
    final service = FlutterBackgroundService();
    await service.startService();
    setState(() {
      _isMonitoring = true;
      _statusMessage = "監視開始\n体につけてください";
    });
    _listenToStatus();
  }

  void _stopMonitoring() {
    FlutterBackgroundService().invoke('stopService');
    setState(() {
      _isMonitoring = false;
      _statusMessage = "停止中";
    });
    _statusSubscription?.cancel();
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
              height: MediaQuery.of(context).size.height * 0.9,
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
                        if (_motionThreshold > 0.1) {
                          setState(() => _motionThreshold -= 0.1);
                          setModalState(() {});
                          _saveSettings();
                        }
                      },
                      onIncrement: () {
                        if (_motionThreshold < 5.0) {
                          setState(() => _motionThreshold += 0.1);
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
                        if (_timeToAlert > 10) {
                          setState(() => _timeToAlert -= 10);
                          setModalState(() {});
                          _saveSettings();
                        }
                      },
                      onIncrement: () {
                        if (_timeToAlert < 300) {
                          setState(() => _timeToAlert += 10);
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
                "Android 13以降では通知を許可してください。\nバックグラウンドで正常に動作しない場合は、設定で「電池の最適化」を解除してください。",
                style: TextStyle(
                  fontSize: 12,
                  color: _isMonitoring ? Colors.white70 : Colors.black54,
                ),
                textAlign: TextAlign.center,
              ),
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
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
