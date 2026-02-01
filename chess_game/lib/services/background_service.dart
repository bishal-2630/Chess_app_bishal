import 'dart:async';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import './mqtt_service.dart';
import './django_auth_service.dart';

class BackgroundServiceInstance {
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    // Configure local notifications for the foreground service tray
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'my_foreground', // id
      'MY FOREGROUND SERVICE', // title
      description:
          'This channel is used for important notifications.', // description
      importance: Importance.low, // low importance so it doesn't pop up
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: 'my_foreground',
        initialNotificationTitle: 'Chess Service',
        initialNotificationContent: 'Running in background to receive calls',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );

    service.startService();
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    // Check if user is logged in before connecting
    final authService = DjangoAuthService();
    await authService.initialize(); // Load from prefs

    // Always register port immediately on start so it can receive stop signals
    final mqttService = MqttService();
    mqttService.initializeIsolateListener(isBackground: true);

    if (authService.isLoggedIn) {
      final username = authService.currentUser?['username'];
      if (username != null) {
        print(
            'Background Service: User logged in, connecting MQTT for $username');
        await mqttService.initialize();
        await mqttService.connect(username);
      }
    }

    // Use service.on for robust communication from Main Isolate
    service.on('stopAudio').listen((event) {
      final roomId = event?['roomId'];
      print('Background Isolate: NUCLEAR STOP triggered via service (roomId: $roomId)');
      if (roomId != null) {
        MqttService().ignoreRoom(roomId);
      }
      MqttService().stopAudio(broadcast: false, roomId: roomId);
    });

    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    // Keep service alive
    Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          // You can update the tray notification here if needed
        }
      }

      // Check connection occasionally
      final authService = DjangoAuthService();
      if (authService.isLoggedIn) {
        final mqtt = MqttService();
        if (!mqtt.isConnected) {
          final username = authService.currentUser?['username'];
          if (username != null) {
            // Ensure port is registered even if service restarted/woke up
            mqtt.initializeIsolateListener(isBackground: true);
            await mqtt.connect(username);
          }
        }
      }
    });
  }
}
